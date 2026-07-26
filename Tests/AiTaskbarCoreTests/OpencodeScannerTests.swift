import Testing
import Foundation
import SQLite3
@testable import AiTaskbarCore
import AiTaskbarTestSupport

/// Builds a throwaway database shaped like opencode's `message` table.
///
/// Hermetic on purpose: the real database is 19 GB, belongs to another running
/// application, and its contents change under us. These fixtures pin the field
/// semantics that were established against it, so a future edit that "tidies"
/// a JSON path or folds reasoning into output fails here instead of quietly
/// reporting wrong numbers on someone's menu bar.
private struct FixtureDB {
    let path: String

    init(rows: [(model: String, provider: String, role: String,
                 createdMs: Int64, input: Int, output: Int, reasoning: Int,
                 cacheRead: Int, cacheWrite: Int, cost: Double)],
         includeModelID: Bool = true) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("opencode.db").path

        var db: OpaquePointer?
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE message (
              id text PRIMARY KEY, session_id text NOT NULL,
              time_created integer NOT NULL, time_updated integer NOT NULL,
              data text NOT NULL);
            """, nil, nil, nil)

        for (i, r) in rows.enumerated() {
            let modelField = includeModelID ? "\"modelID\":\"\(r.model)\"," : ""
            let json = """
                {"role":"\(r.role)",\(modelField)"providerID":"\(r.provider)",\
                "cost":\(r.cost),\
                "tokens":{"input":\(r.input),"output":\(r.output),\
                "reasoning":\(r.reasoning),\
                "cache":{"read":\(r.cacheRead),"write":\(r.cacheWrite)}}}
                """
            let sql = "INSERT INTO message VALUES ('m\(i)','s0',\(r.createdMs),\(r.createdMs),?)"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }
}

private let now = Date(timeIntervalSince1970: 1_784_000_000)   // fixed clock
private func msAgo(_ seconds: Double) -> Int64 {
    Int64((now.timeIntervalSince1970 - seconds) * 1000)
}

@Suite("OpencodeScanner")
struct OpencodeScannerTests {

    /// INVARIANT 1. `tokens.input` already excludes `tokens.cache.read`, so the
    /// scanner must carry it across untouched. Codex's rollout format is the
    /// opposite — input there is inclusive — and a reader written from that
    /// assumption would either add the two together or subtract one from the
    /// other. This fixture makes both mistakes visible: input is deliberately
    /// tiny next to a 200k cache read, the shape seen on the real database.
    @Test("input is cache-exclusive and is not merged with cache read")
    func input_excludes_cache_read() {
        let db = FixtureDB(rows: [
            (model: "gpt-5.6-sol", provider: "openai", role: "assistant",
             createdMs: msAgo(3600), input: 500, output: 100, reasoning: 0,
             cacheRead: 200_000, cacheWrite: 0, cost: 0),
        ])
        let scan = OpencodeScanner.scan(now: now, provider: "openai", dbPath: db.path)
        let usage = scan?.last7DaysByModel["gpt-5.6-sol"]
        #expect(usage?.inputTokens == 500)           // NOT 200_500
        #expect(usage?.cacheReadTokens == 200_000)   // NOT 0, NOT folded away
    }

    /// INVARIANT 2. `reasoning` is a sibling of `output`, not a slice of it —
    /// 6458 of 21910 real assistant turns report `reasoning > output`, which no
    /// subset can do. Billed output is the sum. A fixture where reasoning
    /// exceeds output would be impossible under the subset reading, so it fails
    /// loudly if anyone "corrects" this back.
    @Test("reasoning is disjoint from output and adds to it")
    func reasoning_adds_to_output() {
        let db = FixtureDB(rows: [
            (model: "grok-4.5", provider: "xai", role: "assistant",
             createdMs: msAgo(3600), input: 10, output: 300, reasoning: 900,
             cacheRead: 0, cacheWrite: 0, cost: 1.5),
        ])
        let scan = OpencodeScanner.scan(now: now, provider: "xai", dbPath: db.path)
        #expect(scan?.last7DaysByModel["grok-4.5"]?.outputTokens == 1200)
    }

    /// Attribution is per message. Two models inside one session must land in
    /// their own buckets — this is the whole reason the scanner does not read
    /// `session.model`, which holds only the last model a session used.
    @Test("a session mixing two models splits per model, not per session")
    func mixed_model_session_splits() {
        let db = FixtureDB(rows: [
            (model: "glm-5.2", provider: "openai", role: "assistant",
             createdMs: msAgo(3600), input: 8_000, output: 10, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
            (model: "gpt-5.6-sol", provider: "openai", role: "assistant",
             createdMs: msAgo(3500), input: 25, output: 5, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
        ])
        let scan = OpencodeScanner.scan(now: now, provider: "openai", dbPath: db.path)
        #expect(scan?.last7DaysByModel["glm-5.2"]?.inputTokens == 8_000)
        #expect(scan?.last7DaysByModel["gpt-5.6-sol"]?.inputTokens == 25)
        #expect(scan?.last7DaysByModel.count == 2)
    }

    @Test("only the requested provider is counted")
    func provider_is_filtered() {
        let db = FixtureDB(rows: [
            (model: "gpt-5.6-sol", provider: "openai", role: "assistant",
             createdMs: msAgo(3600), input: 100, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
            (model: "grok-4.5", provider: "xai", role: "assistant",
             createdMs: msAgo(3600), input: 999, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 7),
        ])
        let openai = OpencodeScanner.scan(now: now, provider: "openai", dbPath: db.path)
        #expect(openai?.last7DaysByModel.count == 1)
        #expect(openai?.last7DaysByModel["grok-4.5"] == nil)

        let xai = OpencodeScanner.scan(now: now, provider: "xai", dbPath: db.path)
        #expect(xai?.last7DaysByModel["grok-4.5"]?.inputTokens == 999)
        #expect(xai?.costLast7DaysByModel["grok-4.5"] == 7)
    }

    /// The 7-day window must contain today's rows too — an off-by-one that
    /// makes the windows disjoint is easy to write and shows up as a card whose
    /// weekly number is smaller than its daily one.
    @Test("today is a subset of the 7-day window, not a sibling of it")
    func today_is_inside_seven_days() {
        let db = FixtureDB(rows: [
            (model: "m", provider: "p", role: "assistant",
             createdMs: msAgo(60), input: 10, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 1),          // now-ish
            (model: "m", provider: "p", role: "assistant",
             createdMs: msAgo(4 * 86_400), input: 90, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 9),          // 4 days back
        ])
        let scan = OpencodeScanner.scan(now: now, provider: "p", dbPath: db.path)
        #expect(scan?.last7DaysByModel["m"]?.inputTokens == 100)
        #expect(scan?.todayByModel["m"]?.inputTokens == 10)
        #expect(scan?.costLast7DaysByModel["m"] == 10)
        #expect(scan?.costTodayByModel["m"] == 1)
    }

    @Test("rows older than seven days are excluded")
    func old_rows_excluded() {
        let db = FixtureDB(rows: [
            (model: "m", provider: "p", role: "assistant",
             createdMs: msAgo(30 * 86_400), input: 5_000, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 50),
        ])
        let scan = OpencodeScanner.scan(now: now, provider: "p", dbPath: db.path)
        expectTrue(scan?.isEmpty == true)
    }

    /// User turns carry no token accounting; counting them would inflate the
    /// message count and, if any ever carried a stray `tokens` object, the
    /// totals.
    @Test("non-assistant rows are ignored")
    func only_assistant_rows() {
        let db = FixtureDB(rows: [
            (model: "m", provider: "p", role: "user",
             createdMs: msAgo(60), input: 1_000, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 3),
        ])
        let scan = OpencodeScanner.scan(now: now, provider: "p", dbPath: db.path)
        expectTrue(scan?.isEmpty == true)
    }

    /// An unattributable turn is counted, not silently dropped and not folded
    /// into some arbitrary model — the same reason `CodexSessionScanner` tracks
    /// its own losses.
    @Test("turns without a modelID are counted as skipped")
    func missing_model_is_reported() {
        let db = FixtureDB(rows: [
            (model: "ignored", provider: "p", role: "assistant",
             createdMs: msAgo(60), input: 10, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
        ], includeModelID: false)
        let scan = OpencodeScanner.scan(now: now, provider: "p", dbPath: db.path)
        #expect(scan?.skippedRows == 1)
        expectTrue(scan?.todayByModel.isEmpty == true)
    }

    /// Absent database must be distinguishable from a database with no usage:
    /// "opencode isn't installed" and "you used nothing" are different cards.
    @Test("a missing database returns nil rather than an empty scan")
    func missing_database_is_nil() {
        let scan = OpencodeScanner.scan(
            now: now, provider: "openai",
            dbPath: "/nonexistent/\(UUID().uuidString)/opencode.db")
        expectTrue(scan == nil)
    }

    /// Opt-in read of the real database. Off by default — it is 19 GB, belongs
    /// to another application, and its contents differ per machine.
    ///   OPENCODE_REAL_DB=1 swift test --filter real_database
    @Test("real database scan stays coherent", .enabled(if: ProcessInfo.processInfo
        .environment["OPENCODE_REAL_DB"] == "1"))
    func real_database() {
        let scan = OpencodeScanner.scan(now: Date(), provider: "openai")
        guard let scan else { return }
        for (model, usage) in scan.todayByModel {
            let weekly = scan.last7DaysByModel[model]
            #expect(weekly != nil)
            expectTrue(usage.inputTokens <= (weekly?.inputTokens ?? 0))
            expectTrue(usage.outputTokens <= (weekly?.outputTokens ?? 0))
        }
    }
}
