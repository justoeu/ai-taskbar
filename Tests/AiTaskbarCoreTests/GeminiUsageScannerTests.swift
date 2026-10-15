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
                                     orphanStep: Bool = false,
                                     extraGenBlobs: [Data] = []) throws {
        struct FixtureError: Error { let step: String }
        let dir = home.appendingPathComponent("antigravity-cli/conversations")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw FixtureError(step: "open")
        }
        defer { sqlite3_close(db) }
        let created = sqlite3_exec(db, """
            CREATE TABLE steps (idx integer, step_type integer NOT NULL DEFAULT 0,
              status integer NOT NULL DEFAULT 0, metadata blob, PRIMARY KEY (idx));
            CREATE TABLE gen_metadata (idx integer, data blob,
              size integer NOT NULL DEFAULT 0, PRIMARY KEY (idx));
            """, nil, nil, nil)
        guard created == SQLITE_OK else { throw FixtureError(step: "schema") }
        func insert(_ sql: String, blob: Data, idx: Int, stepType: Int?) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw FixtureError(step: "prepare")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(idx))
            if let stepType { sqlite3_bind_int(stmt, 2, Int32(stepType)) }
            let pos = stepType == nil ? 2 : 3
            _ = blob.withUnsafeBytes {
                sqlite3_bind_blob(stmt, Int32(pos), $0.baseAddress, Int32(blob.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw FixtureError(step: "insert") }
        }
        for (i, g) in gens.enumerated() {
            // The generation's own usage copy deliberately differs from the
            // step's (input +7, cache +3): usage must come from the STEP.
            try insert("INSERT INTO gen_metadata VALUES (?, ?, 0)",
                   blob: genBlob(model: g.model, id: g.id, input: g.input + 7, output: g.output,
                                 cache: g.cache + 3, thinking: g.thinking),
                   idx: i, stepType: nil)
            try insert("INSERT INTO steps VALUES (?, ?, 3, ?)",
                   blob: stepMeta(epoch: g.epoch, id: g.id, input: g.input, output: g.output,
                                  cache: g.cache, thinking: g.thinking),
                   idx: i * 2 + 1, stepType: 15)
        }
        for (j, blob) in extraGenBlobs.enumerated() {
            try insert("INSERT INTO gen_metadata VALUES (?, ?, 0)", blob: blob, idx: 500 + j, stepType: nil)
        }
        if orphanStep {
            try insert("INSERT INTO steps VALUES (?, ?, 3, ?)",
                   blob: stepMeta(epoch: gens.first?.epoch ?? 0, id: "orphan-id",
                                  input: 999, output: 999, cache: 0, thinking: 0),
                   idx: 999, stepType: 15)
        }
    }

    // MARK: - Gemini CLI JSONL

    @Test("CLI chats: cached subset subtracted, thoughts added to output, dup ids counted once")
    func cli_chats_semantics() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let window = CostWindow(now: now)
        let today = window.startOfToday.addingTimeInterval(3600)
        let line = """
            {"id":"m1","type":"gemini","model":"gemini-4-argon","timestamp":"\(iso(today))",\
            "tokens":{"input":1000,"output":100,"cached":400,"thoughts":50,"tool":0,"total":1150}}
            """
        let userLine = """
            {"id":"u1","type":"user","timestamp":"\(iso(today))","content":"hi"}
            """
        // Same id rewritten while streaming: a smaller partial, the final
        // row, then the final again — counted once, at the LARGEST total.
        let partial = """
            {"id":"m1","type":"gemini","model":"gemini-4-argon","timestamp":"\(iso(today))",\
            "tokens":{"input":1000,"output":10,"cached":400,"thoughts":5,"tool":0,"total":1015}}
            """
        try writeChat(home: home, lines: [partial, line, line, userLine])

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
        defer { try? FileManager.default.removeItem(at: home) }
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
        defer { try? FileManager.default.removeItem(at: home) }
        let window = CostWindow(now: now)
        let epoch = Int64(window.startOfToday.timeIntervalSince1970) + 3600
        try writeConversationDB(home: home, name: "conv-1.db", gens: [
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
        defer { try? FileManager.default.removeItem(at: home) }
        let window = CostWindow(now: now)
        let epoch = Int64(window.startOfToday.timeIntervalSince1970) + 7200
        try writeConversationDB(home: home, name: "conv-2.db", gens: [
            (model: "gemini-3.8-flash-high", id: "r1", input: 4712, output: 132, cache: 123765, thinking: 45, epoch: epoch),
            (model: "claude-opus-5-5-high", id: "r2", input: 2000, output: 300, cache: 0, thinking: 100, epoch: epoch),
        ], orphanStep: true)

        let est = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        let flash = try #require(est.totalsByModel["gemini-3.8-flash-high"])
        #expect(flash.inputTokens == 4712)       // NOT 4712 + cache, NOT 4712 - cache
        #expect(flash.cacheReadTokens == 123765)
        #expect(flash.outputTokens == 132)
        // Orphan step (no matching gen_metadata, 999 tokens) contributes
        // nothing to any model.
        let totalInput = est.totalsByModel.values.reduce(0) { $0 + $1.inputTokens }
        #expect(totalInput == 4712 + 2000)
        // Claude used via Antigravity is reported, and priced at Anthropic rates.
        #expect(est.totalsByModel["claude-opus-5-5-high"]?.inputTokens == 2000)
        #expect(est.unpricedModelsToday.isEmpty)
    }

    @Test("Missing .gemini directory yields an empty, noted estimate")
    func missing_home() throws {
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("does-not-exist")
        let est = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        #expect(est.usdToday == 0)
        #expect(est.totalsByModel.isEmpty)
        #expect(est.note != nil)
    }

    @Test("CLI chats: an Int.max token count saturates instead of trapping")
    func cli_overflow_saturates() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let at = CostWindow(now: now).startOfToday.addingTimeInterval(60)
        try writeChat(home: home, lines: ["""
            {"id":"big","type":"gemini","model":"gemini-4-argon","timestamp":"\(iso(at))",\
            "tokens":{"input":1,"output":9223372036854775807,"thoughts":1}}
            """])
        let est = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        #expect(est.totalsByModel["gemini-4-argon"]?.outputTokens == Int.max)
    }

    @Test("malformed records are counted as drift in the note")
    func drift_is_reported() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let epoch = Int64(CostWindow(now: now).startOfToday.timeIntervalSince1970) + 60
        try writeChat(home: home, lines: [#"{"id":"x","tokens": not json"#])
        try writeConversationDB(home: home, name: "conv-drift.db", gens: [
            (model: "gemini-4-argon", id: "ok", input: 10, output: 1, cache: 0, thinking: 0, epoch: epoch),
        ], extraGenBlobs: [Data([0x0a, 0xff, 0xff])])
        let est = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        let note = try #require(est.note)
        expectTrue(note.contains("malformed"))
        #expect(est.totalsByModel["gemini-4-argon"]?.inputTokens == 10)
    }

    @Test("a symlinked .db or session log is never followed")
    func symlinks_are_skipped() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let elsewhere = try makeHome()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let epoch = Int64(CostWindow(now: now).startOfToday.timeIntervalSince1970) + 60
        try writeConversationDB(home: elsewhere, name: "real.db", gens: [
            (model: "gemini-4-argon", id: "r", input: 10, output: 1, cache: 0, thinking: 0, epoch: epoch),
        ])
        let dir = home.appendingPathComponent("antigravity-cli/conversations")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link.db"),
            withDestinationURL: elsewhere.appendingPathComponent("antigravity-cli/conversations/real.db"))
        let est = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        #expect(est.totalsByModel.isEmpty)
    }

    @Test("an unchanged database is replayed from the memo; a changed one is re-read")
    func conversation_memo() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let epoch = Int64(CostWindow(now: now).startOfToday.timeIntervalSince1970) + 60
        let gen1 = (model: "gemini-4-argon", id: "a", input: 10, output: 1, cache: 0, thinking: 0, epoch: epoch)
        try writeConversationDB(home: home, name: "memo.db", gens: [gen1])
        let first = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        let second = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        #expect(first.totalsByModel == second.totalsByModel)
        #expect(second.totalsByModel["gemini-4-argon"]?.inputTokens == 10)

        // Rewrite with a second generation: size/mtime change → re-read.
        try FileManager.default.removeItem(
            at: home.appendingPathComponent("antigravity-cli/conversations/memo.db"))
        let gen2 = (model: "gemini-4-argon", id: "b", input: 20, output: 2, cache: 0, thinking: 0, epoch: epoch)
        try writeConversationDB(home: home, name: "memo.db", gens: [gen1, gen2])
        let third = GeminiUsageScanner.estimate(now: now, geminiHome: home)
        #expect(third.totalsByModel["gemini-4-argon"]?.inputTokens == 30)
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
