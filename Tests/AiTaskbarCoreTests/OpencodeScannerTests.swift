import Testing
import Foundation
import SQLite3
@testable import AiTaskbarCore

/// Builds a throwaway database shaped like opencode's `message` table.
///
/// Hermetic on purpose: the real database is 19 GB, belongs to another running
/// application, and its contents change under us. These fixtures pin the field
/// semantics that were established against it, so a future edit that "tidies"
/// a JSON path or folds reasoning into output fails here instead of quietly
/// reporting wrong numbers on someone's menu bar.
private struct FixtureDB {
    let path: String

    enum Layout { case v1, v2, both, neither }

    init(rows: [(model: String, provider: String, role: String,
                 createdMs: Int64, input: Int, output: Int, reasoning: Int,
                 cacheRead: Int, cacheWrite: Int, cost: Double)],
         includeModelID: Bool = true,
         layout: Layout = .v1) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-fixture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("opencode.db").path

        var db: OpaquePointer?
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { sqlite3_close(db) }
        if layout == .v1 || layout == .both {
            sqlite3_exec(db, """
                CREATE TABLE message (
                  id text PRIMARY KEY, session_id text NOT NULL,
                  time_created integer NOT NULL, time_updated integer NOT NULL,
                  data text NOT NULL);
                """, nil, nil, nil)
        }
        if layout == .v2 || layout == .both {
            // opencode 2.x (v2.1.4): role in `type`, model nested under `model`.
            sqlite3_exec(db, """
                CREATE TABLE session_message (
                  id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
                  seq integer NOT NULL, time_created integer NOT NULL,
                  time_updated integer NOT NULL, data text NOT NULL);
                """, nil, nil, nil)
        }
        if layout == .neither {
            sqlite3_exec(db, "CREATE TABLE session (id text PRIMARY KEY);", nil, nil, nil)
        }

        for (i, r) in rows.enumerated() {
            if layout == .v2 || layout == .both {
                let modelField = includeModelID ? "\"id\":\"\(r.model)\"," : ""
                let json = """
                    {"model":{\(modelField)"providerID":"\(r.provider)","variant":"max"},\
                    "cost":\(r.cost),\
                    "tokens":{"input":\(r.input),"output":\(r.output),\
                    "reasoning":\(r.reasoning),\
                    "cache":{"read":\(r.cacheRead),"write":\(r.cacheWrite)}}}
                    """
                let sql = "INSERT INTO session_message VALUES ('v2m\(i)','s0',?,\(i),\(r.createdMs),\(r.createdMs),?)"
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
                sqlite3_bind_text(stmt, 1, r.role, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, json, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            guard layout == .v1 || layout == .both else { continue }
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
            (model: "grok-4.6", provider: "xai", role: "assistant",
             createdMs: msAgo(3600), input: 10, output: 300, reasoning: 900,
             cacheRead: 0, cacheWrite: 0, cost: 1.5),
        ])
        let scan = OpencodeScanner.scan(now: now, provider: "xai", dbPath: db.path)
        #expect(scan?.last7DaysByModel["grok-4.6"]?.outputTokens == 1200)
    }

    @Test("multiple provider aliases merge Z.AI coding-plan usage in one scan")
    func multiple_provider_aliases_merge() {
        let db = FixtureDB(rows: [
            (model: "glm-5.3", provider: "zai-coding-plan", role: "assistant",
             createdMs: msAgo(60), input: 100, output: 20, reasoning: 5,
             cacheRead: 10, cacheWrite: 0, cost: 0),
            (model: "glm-5", provider: "zai", role: "assistant",
             createdMs: msAgo(120), input: 50, output: 10, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
            (model: "grok-4.6", provider: "xai", role: "assistant",
             createdMs: msAgo(180), input: 999, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 1),
        ])
        let scan = OpencodeScanner.scan(
            now: now,
            providers: ["zai", "zai-coding-plan"],
            dbPath: db.path
        )
        #expect(scan?.last7DaysByModel["glm-5.3"]?.inputTokens == 100)
        #expect(scan?.last7DaysByModel["glm-5"]?.inputTokens == 50)
        #expect(scan?.last7DaysByModel["grok-4.6"] == nil)
    }

    @Test("several vendor groups are attributed from one database pass")
    func vendor_groups_are_split() {
        let db = FixtureDB(rows: [
            (model: "glm-5.3", provider: "zai-coding-plan", role: "assistant",
             createdMs: msAgo(60), input: 100, output: 20, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
            (model: "grok-4.6", provider: "xai", role: "assistant",
             createdMs: msAgo(60), input: 50, output: 10, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 1),
        ])

        let scans = OpencodeScanner.scan(
            now: now,
            providerGroups: [
                "zai": ["zai", "zai-coding-plan"],
                "xai": ["xai"],
            ],
            dbPath: db.path)

        #expect(scans?["zai"]?.last7DaysByModel["glm-5.3"]?.inputTokens == 100)
        #expect(scans?["zai"]?.last7DaysByModel["grok-4.6"] == nil)
        #expect(scans?["xai"]?.last7DaysByModel["grok-4.6"]?.inputTokens == 50)
        #expect(scans?["xai"]?.last7DaysByModel["glm-5.3"] == nil)
    }

    @Test("a pre-cancelled task skips the SQLite scan")
    func pre_cancelled_task_skips_scan() async {
        let db = FixtureDB(rows: [
            (model: "glm-5.3", provider: "zai-coding-plan", role: "assistant",
             createdMs: msAgo(60), input: 100, output: 20, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
        ])
        let task = Task.detached {
            // Give the caller a deterministic point at which to cancel before
            // entering the synchronous SQLite scanner.
            try? await Task.sleep(nanoseconds: 50_000_000)
            return OpencodeScanner.scan(
                now: now,
                providers: ["zai-coding-plan"],
                dbPath: db.path
            )
        }
        task.cancel()
        let scan = await task.value
        expectTrue(scan == nil)
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

    /// BUG-ART-006: the window is "today + the six previous local days",
    /// shared with the Claude and Codex scanners. The old rolling
    /// `now - 7 * 86_400` cutoff disagreed with theirs and was added to them.
    @Test("the 7-day window starts at local midnight six days before today")
    func seven_day_window_boundary() throws {
        let cal = Calendar.current
        let windowStart = try #require(cal.date(byAdding: .day, value: -6,
                                                to: cal.startOfDay(for: now)))
        let startMs = Int64(windowStart.timeIntervalSince1970 * 1000)
        let db = FixtureDB(rows: [
            (model: "m", provider: "p", role: "assistant",
             createdMs: startMs + 1_000, input: 10, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 1),          // just inside
            (model: "m", provider: "p", role: "assistant",
             createdMs: startMs - 1_000, input: 90, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 9),          // just outside
        ])
        let scan = OpencodeScanner.scan(now: now, provider: "p", dbPath: db.path)
        #expect(scan?.last7DaysByModel["m"]?.inputTokens == 10)
        #expect(scan?.costLast7DaysByModel["m"] == 1)
    }

    /// DUP-ECO-002: output and reasoning each fit in Int64 (SQLite's sum()
    /// would have raised otherwise), but their sum need not. A bare `+`
    /// trapped and took the whole menu-bar app down with it; the combined
    /// count saturates like every other token sum.
    @Test("output + reasoning near Int.max saturates instead of trapping")
    func output_plus_reasoning_saturates() {
        let huge = Int.max / 2 + 1
        let db = FixtureDB(rows: [
            (model: "m", provider: "p", role: "assistant",
             createdMs: msAgo(60), input: 0, output: huge, reasoning: huge,
             cacheRead: 0, cacheWrite: 0, cost: 0),
        ])
        let scan = OpencodeScanner.scan(now: now, provider: "p", dbPath: db.path)
        #expect(scan?.last7DaysByModel["m"]?.outputTokens == Int.max)
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

    /// CQ-MAE-003: nil used to stand for four different causes, and the app
    /// re-probed `fileExists` to tell "not installed" from "read failed".
    /// The outcome carries the reason itself.
    @Test("scanOutcome tells a missing database from an unreadable one")
    func scan_outcome_distinguishes_causes() throws {
        let missing = OpencodeScanner.scanOutcome(
            now: now, providerGroups: ["openai": ["openai"]],
            dbPath: "/nonexistent/\(UUID().uuidString)/opencode.db")
        #expect(missing == .notInstalled)

        let garbage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-garbage-\(UUID().uuidString).db")
        try Data("not a sqlite database, just bytes".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) } // test cleanup
        let unreadable = OpencodeScanner.scanOutcome(
            now: now, providerGroups: ["openai": ["openai"]], dbPath: garbage.path)
        #expect(unreadable == .unavailable)

        let conflicting = OpencodeScanner.scanOutcome(
            now: now, providerGroups: ["a": ["openai"], "b": ["openai"]],
            dbPath: garbage.path)
        #expect(conflicting == .unavailable)
    }

    @Test("scanOutcome wraps a successful scan")
    func scan_outcome_scanned() {
        let db = FixtureDB(rows: [
            (model: "gpt-5.5", provider: "openai", role: "assistant",
             createdMs: msAgo(60), input: 7, output: 1, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
        ])
        let outcome = OpencodeScanner.scanOutcome(
            now: now, providerGroups: ["openai": ["openai"]], dbPath: db.path)
        guard case .scanned(let scans) = outcome else {
            Issue.record("expected .scanned, got \(outcome)")
            return
        }
        #expect(scans["openai"]?.last7DaysByModel["gpt-5.5"]?.inputTokens == 7)
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

    // MARK: opencode 2.x (`session_message`)

    @Test("2.x database: same token semantics, model and provider from `model`")
    func v2_layout_reads_session_message() {
        let db = FixtureDB(rows: [
            (model: "glm-5.3", provider: "zai", role: "assistant",
             createdMs: msAgo(60), input: 259, output: 163, reasoning: 393,
             cacheRead: 208_576, cacheWrite: 10, cost: 0.057),
        ], layout: .v2)
        let scan = OpencodeScanner.scan(now: now, provider: "zai", dbPath: db.path)
        let usage = scan?.last7DaysByModel["glm-5.3"]
        #expect(usage?.inputTokens == 259)            // cache-exclusive, untouched
        #expect(usage?.outputTokens == 163 + 393)     // reasoning is disjoint: added
        #expect(usage?.cacheReadTokens == 208_576)
        #expect(usage?.cacheCreateTokens == 10)
        #expect(scan?.costLast7DaysByModel["glm-5.3"] == 0.057)
        #expect(scan?.todayByModel["glm-5.3"]?.inputTokens == 259)
    }

    @Test("2.x database: only `type = 'assistant'` rows of the requested provider count")
    func v2_filters_type_and_provider() {
        let db = FixtureDB(rows: [
            (model: "glm-5.3", provider: "zai", role: "assistant",
             createdMs: msAgo(60), input: 100, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
            (model: "glm-5.3", provider: "zai", role: "user",
             createdMs: msAgo(60), input: 9_999, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
            (model: "claude-opus-5-5", provider: "anthropic", role: "assistant",
             createdMs: msAgo(60), input: 7, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
        ], layout: .v2)
        let scan = OpencodeScanner.scan(now: now, provider: "zai", dbPath: db.path)
        #expect(scan?.last7DaysByModel["glm-5.3"]?.inputTokens == 100)
        #expect(scan?.last7DaysByModel["claude-opus-5-5"] == nil)
    }

    @Test("2.x database: a turn without `model.id` is skipped and counted")
    func v2_missing_model_is_skipped() {
        let db = FixtureDB(rows: [
            (model: "x", provider: "zai", role: "assistant",
             createdMs: msAgo(60), input: 1, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
        ], includeModelID: false, layout: .v2)
        let scan = OpencodeScanner.scan(now: now, provider: "zai", dbPath: db.path)
        #expect(scan?.skippedRows == 1)
        expectTrue(scan?.isEmpty ?? false)
    }

    @Test("both layouts present: turns copied into 2.x are counted once")
    func both_layouts_prefer_v2() {
        let db = FixtureDB(rows: [
            (model: "glm-5.3", provider: "zai", role: "assistant",
             createdMs: msAgo(60), input: 100, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
        ], layout: .both)
        let scan = OpencodeScanner.scan(now: now, provider: "zai", dbPath: db.path)
        #expect(scan?.last7DaysByModel["glm-5.3"]?.inputTokens == 100)   // NOT 200
    }

    @Test("both layouts present: 1.x turns older than the first 2.x turn are kept")
    func both_layouts_keep_old_v1_turns() throws {
        // Upgrade without a copy: the week's older turns live only in `message`.
        let db = FixtureDB(rows: [
            (model: "glm-5.3", provider: "zai", role: "assistant",
             createdMs: msAgo(60), input: 100, output: 0, reasoning: 0,
             cacheRead: 0, cacheWrite: 0, cost: 0),
        ], layout: .v2)
        var handle: OpaquePointer?
        sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(handle) }
        sqlite3_exec(handle, """
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL,
              time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
            INSERT INTO message VALUES ('old', 's0', \(msAgo(86_400)), \(msAgo(86_400)),
              '{"role":"assistant","modelID":"glm-5.3","providerID":"zai","cost":0,"tokens":{"input":40,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}');
            INSERT INTO message VALUES ('newer', 's0', \(msAgo(30)), \(msAgo(30)),
              '{"role":"assistant","modelID":"glm-5.3","providerID":"zai","cost":0,"tokens":{"input":9999,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}');
            """, nil, nil, nil)
        let scan = OpencodeScanner.scan(now: now, provider: "zai", dbPath: db.path)
        // 100 from 2.x + 40 from the older 1.x turn; the 1.x turn after the
        // first 2.x turn is left to 2.x (would be a copy).
        #expect(scan?.last7DaysByModel["glm-5.3"]?.inputTokens == 140)
    }

    @Test("an unknown layout (neither table) is unavailable, not an empty scan")
    func unknown_layout_is_unavailable() {
        let db = FixtureDB(rows: [], layout: .neither)
        let outcome = OpencodeScanner.scanOutcome(now: now, providerGroups: ["zai": ["zai"]],
                                                  dbPath: db.path)
        #expect(outcome == .unavailable)
    }

    @Test("tokens are bucketed into the seven CostWindow days, oldest first")
    func daily_series_buckets_by_local_day() throws {
        let window = CostWindow(now: now)
        let days = window.calendarDays()
        func ms(_ d: Date, plus seconds: Double = 60) -> Int64 { Int64((d.timeIntervalSince1970 + seconds) * 1000) }
        let db = FixtureDB(rows: [
            (model: "glm-5.3", provider: "zai", role: "assistant",
             createdMs: ms(days[0]), input: 11, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, cost: 0),
            (model: "glm-5.3", provider: "zai", role: "assistant",
             createdMs: ms(days[3]), input: 33, output: 2, reasoning: 1, cacheRead: 0, cacheWrite: 0, cost: 0),
            (model: "glm-5.3", provider: "zai", role: "assistant",
             createdMs: ms(days[6], plus: 1), input: 66, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, cost: 0),
        ], layout: .v2)
        let scan = try #require(OpencodeScanner.scan(now: now, provider: "zai", dbPath: db.path))
        #expect(scan.daily.count == 7)
        #expect(scan.daily.map(\.date) == days)
        #expect(scan.daily[0].usageByModel["glm-5.3"]?.inputTokens == 11)
        #expect(scan.daily[3].usageByModel["glm-5.3"]?.outputTokens == 3)   // reasoning added
        #expect(scan.daily[6].usageByModel["glm-5.3"]?.inputTokens == 66)
        #expect(scan.daily[1].usageByModel.isEmpty)
        #expect(scan.todayByModel["glm-5.3"]?.inputTokens == 66)
        #expect(scan.last7DaysByModel["glm-5.3"]?.inputTokens == 110)
        #expect(scan.daily.allSatisfy { $0.costByModel.isEmpty })
    }
}
