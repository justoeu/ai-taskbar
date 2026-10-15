import Testing
import Foundation
import SQLite3
@testable import AiTaskbarCore

/// Field semantics pinned against real local records on 2026-10-14:
///
/// - Gemini CLI (`~/.gemini/tmp/*/chats/session-*.jsonl`): rows with
///   `type == "gemini"` carry `tokens{input,output,cached,thoughts,tool,total}`.
///   Measured on 41 rows: `total == input + output + thoughts` always, and
///   `cached <= input` always — so cached is a subset of input (subtract,
///   Codex-style) and thoughts are separate from output (add, opencode-style).
///   The same `id` repeats with identical counts (streaming rewrites):
///   dedupe by id, keeping the largest total.
/// - Antigravity (`~/.gemini/antigravity-cli/conversations/*.db`): protobuf
///   field numbers have no names, so they were calibrated against
///   `agy --output-format json --print` ground truth (one "ok" prompt:
///   input 15535, output 26, thinking 21, cache_read 0). The usage message
///   (gen_metadata `1.4`, mirrored in steps metadata field 9) is:
///   2=input (non-cached), 3=output, 5=cache_read (absent = 0),
///   9=thinking, 10=text output, 11=response id. Verified on 3 real
///   generations: `field3 == field9 + field10`, so thinking is folded
///   into output — never add it. Model = gen_metadata `1.19`; the join
///   key to a step's timestamp is the response id (`1.4.11` == `9.11`).
@Suite("GeminiUsageScanner")
struct GeminiUsageScannerTests {

    // MARK: - Fixtures

    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func makeHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func writeChat(home: URL, lines: [String]) throws {
        let chats = home.appendingPathComponent("tmp/proj/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: chats.appendingPathComponent("session-2026-10-14T00-00-abc.jsonl"),
                       atomically: true, encoding: .utf8)
    }

    // Minimal protobuf encoder for the calibrated layouts above.
    private func varint(_ v: UInt64) -> Data {
        var value = v
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }

    private func fVar(_ field: Int, _ v: UInt64) -> Data { varint(UInt64(field) << 3) + varint(v) }
    private func fBytes(_ field: Int, _ d: Data) -> Data {
        varint((UInt64(field) << 3) | 2) + varint(UInt64(d.count)) + d
    }
    private func fStr(_ field: Int, _ s: String) -> Data { fBytes(field, Data(s.utf8)) }

    private func usageMsg(id: String, input: Int, output: Int, cache: Int, thinking: Int) -> Data {
        var d = fVar(2, UInt64(input)) + fVar(3, UInt64(output))
        if cache > 0 { d += fVar(5, UInt64(cache)) }
        d += fVar(9, UInt64(thinking)) + fVar(10, UInt64(output - thinking)) + fStr(11, id)
        return d
    }

    private func genBlob(model: String, id: String, input: Int, output: Int, cache: Int, thinking: Int) -> Data {
        let msg1 = fBytes(4, usageMsg(id: id, input: input, output: output, cache: cache, thinking: thinking))
            + fStr(19, model)
        return fBytes(1, msg1)
    }

    private func stepMeta(epoch: Int64, id: String, input: Int, output: Int, cache: Int, thinking: Int) -> Data {
        let ts = fVar(1, UInt64(epoch)) + fVar(2, 0)
        return fBytes(1, ts)
            + fBytes(9, usageMsg(id: id, input: input, output: output, cache: cache, thinking: thinking))
    }

    private func writeConversationDB(home: URL, name: String,
                                     gens: [(model: String, id: String, input: Int, output: Int, cache: Int, thinking: Int, epoch: Int64)],
                                     orphanStep: Bool = false) {
        let dir = home.appendingPathComponent("antigravity-cli/conversations")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        var db: OpaquePointer?
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE steps (idx integer, step_type integer NOT NULL DEFAULT 0,
              status integer NOT NULL DEFAULT 0, metadata blob, PRIMARY KEY (idx));
            CREATE TABLE gen_metadata (idx integer, data blob,
              size integer NOT NULL DEFAULT 0, PRIMARY KEY (idx));
            """, nil, nil, nil)
        func insert(_ sql: String, blob: Data, idx: Int, stepType: Int?) {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, Int32(idx))
            if let stepType { sqlite3_bind_int(stmt, 2, Int32(stepType)) }
            let pos = stepType == nil ? 2 : 3
            _ = blob.withUnsafeBytes {
                sqlite3_bind_blob(stmt, Int32(pos), $0.baseAddress, Int32(blob.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        for (i, g) in gens.enumerated() {
            insert("INSERT INTO gen_metadata VALUES (?, ?, 0)",
                   blob: genBlob(model: g.model, id: g.id, input: g.input, output: g.output,
                                 cache: g.cache, thinking: g.thinking),
                   idx: i, stepType: nil)
            insert("INSERT INTO steps VALUES (?, ?, 3, ?)",
                   blob: stepMeta(epoch: g.epoch, id: g.id, input: g.input, output: g.output,
                                  cache: g.cache, thinking: g.thinking),
                   idx: i * 2 + 1, stepType: 15)
        }
        if orphanStep {
            insert("INSERT INTO steps VALUES (?, ?, 3, ?)",
                   blob: stepMeta(epoch: gens.first?.epoch ?? 0, id: "orphan-id",
                                  input: 999, output: 999, cache: 0, thinking: 0),
                   idx: 999, stepType: 15)
        }
    }

    // MARK: - Gemini CLI JSONL

    @Test("CLI chats: cached subset subtracted, thoughts added to output, dup ids counted once")
    func cli_chats_semantics() throws {
        let home = try makeHome()
        let window = CostWindow(now: now)
        let today = window.startOfToday.addingTimeInterval(3600)
        let line = """
            {"id":"m1","type":"gemini","model":"gemini-4-argon","timestamp":"\(iso(today))",\
            "tokens":{"input":1000,"output":100,"cached":400,"thoughts":50,"tool":0,"total":1150}}
            """
        let userLine = """
            {"id":"u1","type":"user","timestamp":"\(iso(today))","content":"hi"}
            """
        // Same id written twice (streaming rewrite) must count once.
        try writeChat(home: home, lines: [line, line, userLine])

        let est = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        let usage = try #require(est.totalsByModel["gemini-4-argon"])
        #expect(usage.inputTokens == 600)        // 1000 - 400 cached
        #expect(usage.cacheReadTokens == 400)
        #expect(usage.outputTokens == 150)       // 100 + 50 thoughts
        // Priced at the Argon introductory rates ($2/$10, cache $0.10 per 1M).
        let expected = (600 * 2.0 + 400 * 0.10 + 150 * 10.0) / 1_000_000
        #expect(abs(est.usdToday - expected) < 1e-12)
    }

    @Test("CLI chats: rows outside the 7-day window are ignored")
    func cli_chats_window() throws {
        let home = try makeHome()
        let window = CostWindow(now: now)
        let old = window.startOfLast7Days.addingTimeInterval(-3600)
        let inWeek = window.startOfLast7Days.addingTimeInterval(3600)
        func makeLine(_ id: String, _ at: Date) -> String {
            """
            {"id":"\(id)","type":"gemini","model":"gemini-3.8-flash-high","timestamp":"\(iso(at))",\
            "tokens":{"input":500,"output":10,"cached":0,"thoughts":0,"tool":0,"total":510}}
            """
        }
        try writeChat(home: home, lines: [makeLine("old", old), makeLine("week", inWeek)])

        let est = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        #expect(est.totalsByModel.isEmpty)       // nothing today
        #expect(est.modelBreakdownLast7Days["gemini-3.8-flash-high"] != nil)
    }

    // MARK: - Antigravity conversations

    @Test("Antigravity: calibration values map to input/output with thinking folded")
    func antigravity_calibration() throws {
        let home = try makeHome()
        let window = CostWindow(now: now)
        let epoch = Int64(window.startOfToday.timeIntervalSince1970) + 3600
        writeConversationDB(home: home, name: "conv-1.db", gens: [
            (model: "gemini-4-argon", id: "respA", input: 15535, output: 26, cache: 0, thinking: 21, epoch: epoch),
        ])

        let est = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        let usage = try #require(est.totalsByModel["gemini-4-argon"])
        #expect(usage.inputTokens == 15535)
        #expect(usage.outputTokens == 26)        // thinking NOT added again
        #expect(usage.cacheReadTokens == 0)
    }

    @Test("Antigravity: cache_read is separate from input; orphan step skipped; models split")
    func antigravity_cache_and_join() throws {
        let home = try makeHome()
        let window = CostWindow(now: now)
        let epoch = Int64(window.startOfToday.timeIntervalSince1970) + 7200
        writeConversationDB(home: home, name: "conv-2.db", gens: [
            (model: "gemini-3.8-flash-high", id: "r1", input: 4712, output: 132, cache: 123765, thinking: 45, epoch: epoch),
            (model: "claude-opus-5-5-high", id: "r2", input: 2000, output: 300, cache: 0, thinking: 100, epoch: epoch),
        ], orphanStep: true)

        let est = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        let flash = try #require(est.totalsByModel["gemini-3.8-flash-high"])
        #expect(flash.inputTokens == 4712)       // NOT 4712 + cache, NOT 4712 - cache
        #expect(flash.cacheReadTokens == 123765)
        #expect(flash.outputTokens == 132)
        // Orphan step (no matching gen_metadata) contributes nothing.
        #expect(est.totalsByModel.count == 2)
        // Third-party model used via Antigravity is reported (tokens; pricing
        // falls back to unpriced in the Gemini table if absent).
        #expect(est.totalsByModel["claude-opus-5-5-high"]?.inputTokens == 2000)
    }

    @Test("Missing .gemini directory yields an empty, noted estimate")
    func missing_home() throws {
        let home = try makeHome().appendingPathComponent("does-not-exist")
        let est = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        #expect(est.usdToday == 0)
        #expect(est.totalsByModel.isEmpty)
        #expect(est.note != nil)
    }

    @Test("a WAL database without its -shm still opens (immutable fallback)")
    func wal_without_shm_is_readable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("conv.db").path
        var writer: OpaquePointer?
        #expect(sqlite3_open_v2(path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        sqlite3_exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE t(x); INSERT INTO t VALUES (1);", nil, nil, nil)
        sqlite3_close(writer)
        // What Antigravity leaves behind: WAL mode in the header, no sidecars.
        try? FileManager.default.removeItem(atPath: path + "-shm")
        try? FileManager.default.removeItem(atPath: path + "-wal")

        // Plain mode=ro opens, then fails its first read — the original bug.
        var plain: OpaquePointer?
        #expect(sqlite3_open_v2("file:\(path)?mode=ro", &plain,
                                SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK)
        #expect(sqlite3_exec(plain, "SELECT count(*) FROM t", nil, nil, nil) != SQLITE_OK)
        sqlite3_close(plain)

        let db = try #require(GeminiUsageScanner.openReadOnly(path))
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "SELECT count(*) FROM t", nil, nil, nil) == SQLITE_OK)
        #expect(!FileManager.default.fileExists(atPath: path + "-shm"))
    }

    @Test("Claude models routed by Antigravity are priced at Anthropic rates")
    func antigravity_prices_claude() throws {
        let claude = try #require(PricingTable.lookup("claude-opus-5-5-high", table: PricingTable.antigravity))
        let anthropic = try #require(PricingTable.lookup("claude-opus-5-5", table: PricingTable.anthropic))
        #expect(claude.inputPer1M == anthropic.inputPer1M)
        #expect(claude.outputPer1M == anthropic.outputPer1M)
        let argon = try #require(PricingTable.lookup("gemini-4-argon", table: PricingTable.antigravity))
        #expect(argon.inputPer1M == 2.0)
    }
}
