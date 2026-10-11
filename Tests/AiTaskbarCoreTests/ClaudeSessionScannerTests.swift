import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("ClaudeSessionScanner.scan token accumulation")
struct ClaudeSessionScannerTests {
    private static func assistantLine(timestamp: String,
                                      model: String,
                                      input: Int = 0,
                                      output: Int = 0,
                                      cacheCreate: Int = 0,
                                      cacheCreate5m: Int = 0,
                                      cacheCreate1h: Int = 0,
                                      cacheRead: Int = 0) -> String {
        #"""
        {"timestamp":"\#(timestamp)","message":{"role":"assistant","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheCreate),"cache_creation":{"ephemeral_5m_input_tokens":\#(cacheCreate5m),"ephemeral_1h_input_tokens":\#(cacheCreate1h)},"cache_read_input_tokens":\#(cacheRead)}}}
        """#
    }

    @Test("today and 7-day buckets fill from assistant lines")
    func today_and_week_buckets_fill() {
        let now = Date(timeIntervalSince1970: 1_764_000_000)  // 2025-11-24
        let cal = Calendar(identifier: .gregorian)
        let startOfToday = cal.startOfDay(for: now)
        let sevenDaysAgo = startOfToday.addingTimeInterval(-7 * 86_400)
        let todayISO = ISO8601DateFormatter().string(
            from: startOfToday.addingTimeInterval(3_600))
        let weekAgoISO = ISO8601DateFormatter().string(
            from: startOfToday.addingTimeInterval(-3 * 86_400))

        let lines = [
            Self.assistantLine(timestamp: todayISO, model: "claude-opus-4-7",
                               input: 1000, output: 500),
            Self.assistantLine(timestamp: weekAgoISO, model: "claude-haiku-4-5",
                               input: 200, output: 100),
            // Non-assistant line — must be ignored by the byte prefilter.
            #"""
            {"timestamp":"\#(todayISO)","role":"user","content":"hello"}
            """#,
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)

        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var unparseable = 0
        ClaudeSessionScanner.scan(data: data,
                                  startOfToday: startOfToday,
                                  sevenDaysAgo: sevenDaysAgo,
                                  totalsToday: &today,
                                  totalsLast7: &week,
                                  unparseableTimestamps: &unparseable)

        #expect(today["claude-opus-4-7"]?.inputTokens == 1000)
        #expect(today["claude-opus-4-7"]?.outputTokens == 500)
        #expect(today["claude-haiku-4-5"] == nil)
        #expect(week["claude-opus-4-7"]?.inputTokens == 1000)
        #expect(week["claude-haiku-4-5"]?.inputTokens == 200)
        #expect(unparseable == 0)
    }

    @Test("synthetic and bracketed pseudo-models are ignored")
    func synthetic_models_ignored() {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let cal = Calendar(identifier: .gregorian)
        let startOfToday = cal.startOfDay(for: now)
        let sevenDaysAgo = startOfToday.addingTimeInterval(-7 * 86_400)
        let todayISO = ISO8601DateFormatter().string(from: startOfToday.addingTimeInterval(3_600))

        let lines = [
            Self.assistantLine(timestamp: todayISO, model: "<synthetic>", input: 500, output: 250),
            Self.assistantLine(timestamp: todayISO, model: "<unknown>", input: 300, output: 100),
            Self.assistantLine(timestamp: todayISO, model: "claude-sonnet-4-5", input: 800, output: 400),
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)

        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var unparseable = 0
        ClaudeSessionScanner.scan(data: data,
                                  startOfToday: startOfToday,
                                  sevenDaysAgo: sevenDaysAgo,
                                  totalsToday: &today,
                                  totalsLast7: &week,
                                  unparseableTimestamps: &unparseable)

        #expect(today["<synthetic>"] == nil)
        #expect(today["<unknown>"] == nil)
        #expect(today["claude-sonnet-4-5"]?.inputTokens == 800)
        #expect(week["<synthetic>"] == nil)
    }

    @Test("missing/invalid timestamp counts into both buckets and is flagged")
    func missing_timestamp_falls_back_and_counts() {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let cal = Calendar(identifier: .gregorian)
        let startOfToday = cal.startOfDay(for: now)
        let sevenDaysAgo = startOfToday.addingTimeInterval(-7 * 86_400)

        // Invalid ISO string — fails both ISO formatters.
        let line = Self.assistantLine(timestamp: "not-a-timestamp",
                                       model: "claude-opus-4-7",
                                       input: 100, output: 50)
        let data = Data((line + "\n").utf8)
        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var unparseable = 0
        ClaudeSessionScanner.scan(data: data,
                                  startOfToday: startOfToday,
                                  sevenDaysAgo: sevenDaysAgo,
                                  totalsToday: &today,
                                  totalsLast7: &week,
                                  unparseableTimestamps: &unparseable)
        #expect(unparseable == 1)
        // Fail-safe: counts into BOTH buckets so the user sees the cost.
        #expect(today["claude-opus-4-7"]?.inputTokens == 100)
        #expect(week["claude-opus-4-7"]?.inputTokens == 100)
    }

    @Test("malformed JSON line silently skipped")
    func malformed_json_silently_skipped() {
        let now = Date()
        let cal = Calendar.current
        // Has the prefilter markers ("usage":{ and assistant role) but malformed JSON.
        let line = #"""
        {"timestamp":"x","message":{"role":"assistant","model":"opus","usage":{INVALID
        """#
        let data = Data((line + "\n").utf8)
        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var unparseable = 0
        ClaudeSessionScanner.scan(data: data,
                                  startOfToday: cal.startOfDay(for: now),
                                  sevenDaysAgo: now.addingTimeInterval(-7 * 86_400),
                                  totalsToday: &today,
                                  totalsLast7: &week,
                                  unparseableTimestamps: &unparseable)
        #expect(today.isEmpty)
        #expect(week.isEmpty)
        #expect(unparseable == 0)
    }

    @Test("estimate with projectsDir → returns 'no directory' note")
    func estimate_no_directory_path() {
        let nonexistent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-no-such-\(UUID().uuidString)")
        let est = ClaudeSessionScanner.estimate(projectsDir: nonexistent)
        #expect(est.usdToday == 0)
        expectTrue(est.note?.contains("No ~/.claude/projects directory.") ?? false)
    }

    @Test("estimate with empty projectsDir → returns 'no recent sessions' note")
    func estimate_empty_directory_path() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let est = ClaudeSessionScanner.estimate(projectsDir: dir)
        #expect(est.usdToday == 0)
        expectTrue(est.note?.contains("No recent Claude sessions") ?? false)
    }

    @Test("estimate(now:) on missing ~/.claude/projects returns empty estimate")
    func estimate_without_directory_returns_empty() {
        // Setting HOME to a tmp dir would interfere with other tests, so we
        // just confirm the estimate path doesn't crash and returns
        // isApproximate=true. The exact note text depends on whether the
        // current host has a real ~/.claude/projects.
        let est = ClaudeSessionScanner.estimate()
        #expect(est.isApproximate)
    }

    @Test("accumulates the same model across multiple lines")
    func accumulates_same_model_across_lines() {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let cal = Calendar(identifier: .gregorian)
        let startOfToday = cal.startOfDay(for: now)
        let todayISO = ISO8601DateFormatter().string(
            from: startOfToday.addingTimeInterval(3_600))
        let lines = [
            Self.assistantLine(timestamp: todayISO, model: "claude-opus-4-7",
                               input: 100, output: 50),
            Self.assistantLine(timestamp: todayISO, model: "claude-opus-4-7",
                               input: 200, output: 100),
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var unparseable = 0
        ClaudeSessionScanner.scan(data: data,
                                  startOfToday: startOfToday,
                                  sevenDaysAgo: startOfToday.addingTimeInterval(-7 * 86_400),
                                  totalsToday: &today,
                                  totalsLast7: &week,
                                  unparseableTimestamps: &unparseable)
        #expect(today["claude-opus-4-7"]?.inputTokens == 300)
        #expect(today["claude-opus-4-7"]?.outputTokens == 150)
    }

    @Test("Claude 1-hour cache writes use their distinct published rate")
    func one_hour_cache_writes_are_priced_separately() {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let startOfToday = Calendar(identifier: .gregorian).startOfDay(for: now)
        let timestamp = ISO8601DateFormatter().string(
            from: startOfToday.addingTimeInterval(3_600))
        let line = Self.assistantLine(
            timestamp: timestamp,
            model: "claude-fable-5-1",
            cacheCreate: 2_000_000,
            cacheCreate5m: 1_000_000,
            cacheCreate1h: 1_000_000)
        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var unparseable = 0

        ClaudeSessionScanner.scan(
            data: Data((line + "\n").utf8),
            startOfToday: startOfToday,
            sevenDaysAgo: startOfToday.addingTimeInterval(-7 * 86_400),
            totalsToday: &today,
            totalsLast7: &week,
            unparseableTimestamps: &unparseable)
        let (usd, _) = CostAggregator.price(
            totals: today, table: PricingTable.anthropic)

        // 1M × $12.50 (5m) + 1M × $20.00 (1h).
        #expect(abs(usd - 32.5) < 0.000_001)
    }

    @Test("Claude discloses an observed model whose price is unavailable")
    func unpriced_model_is_disclosed() throws {
        let now = Date()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-claude-unpriced-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = ISO8601DateFormatter().string(from: now)
        let line = Self.assistantLine(
            timestamp: timestamp, model: "claude-future-9", input: 1_000)
        try Data((line + "\n").utf8).write(to: root.appendingPathComponent("session.jsonl"))

        let estimate = ClaudeSessionScanner.estimate(now: now, projectsDir: root)

        #expect(estimate.modelBreakdownLast7Days["claude-future-9"] == 0)
        #expect(estimate.unpricedModelsToday == Set(["claude-future-9"]))
        #expect(estimate.unpricedModelsLast7Days == Set(["claude-future-9"]))
        expectTrue(estimate.note?.localizedCaseInsensitiveContains("price unavailable") ?? false)
    }

    @Test("a fast-mode line fills the fast subsets; a standard line does not")
    func fast_mode_lines_fill_fast_subsets() {
        let startOfToday = Date(timeIntervalSince1970: 1_764_000_000)
        let iso = ISO8601DateFormatter().string(from: startOfToday.addingTimeInterval(60))
        func line(_ speed: String?) -> String {
            let speedField = speed.map { #","speed":"\#($0)""# } ?? ""
            return #"""
            {"timestamp":"\#(iso)","message":{"role":"assistant","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20},"cache_read_input_tokens":40\#(speedField)}}}
            """#
        }
        let data = Data(([line("fast"), line("standard"), line(nil)].joined(separator: "\n") + "\n").utf8)
        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var unparseable = 0
        ClaudeSessionScanner.scan(data: data, startOfToday: startOfToday,
                                  sevenDaysAgo: startOfToday.addingTimeInterval(-7 * 86_400),
                                  totalsToday: &today, totalsLast7: &week,
                                  unparseableTimestamps: &unparseable)
        let u = today["claude-opus-5-5"]
        // All three lines count toward the visible totals…
        #expect(u?.inputTokens == 300)
        #expect(u?.outputTokens == 150)
        // …but only the fast line lands in the premium subsets.
        #expect(u?.fastInputTokens == 100)
        #expect(u?.fastOutputTokens == 50)
        #expect(u?.fastCacheReadTokens == 40)
        #expect(u?.fastCacheCreateTokens == 10)
        #expect(u?.fastCacheCreate1hTokens == 20)
    }

    @Test("Haiku 5.5: a prompt over 100K (cache writes included) is long-context; exactly 100K is not")
    func haiku55_long_context_boundary() {
        let startOfToday = Date(timeIntervalSince1970: 1_764_000_000)
        let iso = ISO8601DateFormatter().string(from: startOfToday.addingTimeInterval(60))
        func line(model: String, input: Int, cacheRead: Int, write5m: Int, write1h: Int) -> String {
            #"""
            {"timestamp":"\#(iso)","message":{"role":"assistant","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":7,"cache_creation_input_tokens":\#(write5m + write1h),"cache_creation":{"ephemeral_5m_input_tokens":\#(write5m),"ephemeral_1h_input_tokens":\#(write1h)},"cache_read_input_tokens":\#(cacheRead)}}}
            """#
        }
        func scan(_ text: String) -> ModelUsage? {
            var today: [String: ModelUsage] = [:]
            var week: [String: ModelUsage] = [:]
            var unparseable = 0
            ClaudeSessionScanner.scan(data: Data((text + "\n").utf8), startOfToday: startOfToday,
                                      sevenDaysAgo: startOfToday.addingTimeInterval(-7 * 86_400),
                                      totalsToday: &today, totalsLast7: &week,
                                      unparseableTimestamps: &unparseable)
            return today.values.first
        }

        // 40K + 50K + 6K + 4K = exactly 100,000: standard rates.
        let atThreshold = scan(line(model: "claude-haiku-5-5", input: 40_000, cacheRead: 50_000,
                                    write5m: 6_000, write1h: 4_000))
        #expect(atThreshold?.inputTokens == 40_000)
        #expect(atThreshold?.longContextInputTokens == 0)
        #expect(atThreshold?.longContextOutputTokens == 0)

        // One more 1h cache-write token tips it over: the WHOLE request moves.
        let over = scan(line(model: "claude-haiku-5-5", input: 40_000, cacheRead: 50_000,
                             write5m: 6_000, write1h: 4_001))
        #expect(over?.inputTokens == 40_000)
        #expect(over?.longContextInputTokens == 40_000)
        #expect(over?.longContextOutputTokens == 7)
        #expect(over?.longContextCacheReadTokens == 50_000)
        #expect(over?.longContextCacheCreateTokens == 6_000)
        #expect(over?.longContextCacheCreate1hTokens == 4_001)

        // A model with no prompt-length tier is never tagged, however long.
        let sonnet = scan(line(model: "claude-sonnet-5-5", input: 900_000, cacheRead: 0,
                               write5m: 0, write1h: 0))
        #expect(sonnet?.inputTokens == 900_000)
        #expect(sonnet?.longContextInputTokens == 0)
    }

    @Test("negative token counts from a hostile transcript are clamped to zero")
    func negative_counts_clamped() {
        let startOfToday = Date(timeIntervalSince1970: 1_764_000_000)
        let iso = ISO8601DateFormatter().string(from: startOfToday.addingTimeInterval(60))
        let line = #"""
        {"timestamp":"\#(iso)","message":{"role":"assistant","model":"claude-opus-5-5","usage":{"input_tokens":-500,"output_tokens":-7,"cache_read_input_tokens":-9,"speed":"fast"}}}
        """#
        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var unparseable = 0
        ClaudeSessionScanner.scan(data: Data((line + "\n").utf8), startOfToday: startOfToday,
                                  sevenDaysAgo: startOfToday.addingTimeInterval(-7 * 86_400),
                                  totalsToday: &today, totalsLast7: &week,
                                  unparseableTimestamps: &unparseable)
        #expect(today["claude-opus-5-5"]?.inputTokens == 0)
        #expect(today["claude-opus-5-5"]?.outputTokens == 0)
        #expect(today["claude-opus-5-5"]?.cacheReadTokens == 0)
        #expect(today["claude-opus-5-5"]?.fastInputTokens == 0)
    }

    // MARK: - Duplicate API responses (BUG-ART-001)
    //
    // Claude Code writes the same API response to the transcript more than
    // once (streaming / tool-use splits), with the same `message.id` and
    // `requestId`. Summing every line inflated tokens and $ by ~1.9x on real
    // data. Each (message.id, requestId) must count once per scan, across
    // files, keeping the line with the largest output.

    private static func keyedLine(timestamp: String, messageId: String?, requestId: String?,
                                  model: String = "claude-opus-4-7",
                                  input: Int = 0, output: Int = 0, cacheRead: Int = 0) -> String {
        let req = requestId.map { #""requestId":"\#($0)","# } ?? ""
        let mid = messageId.map { #""id":"\#($0)","# } ?? ""
        return #"""
        {\#(req)"timestamp":"\#(timestamp)","message":{\#(mid)"role":"assistant","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead)}}}
        """#
    }

    private static func makeProjects(_ files: [String: [String]]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-claude-dedup-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        for (name, lines) in files {
            try Data((lines.joined(separator: "\n") + "\n").utf8)
                .write(to: proj.appendingPathComponent(name))
        }
        return root
    }

    @Test("the same message.id + requestId written twice in one file counts once")
    func duplicate_key_in_one_file_counts_once() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let line = Self.keyedLine(timestamp: ts, messageId: "msg_A", requestId: "req_A",
                                  input: 100, output: 50, cacheRead: 1_000)
        let root = try Self.makeProjects(["s.jsonl": [line, line]])
        defer { try? FileManager.default.removeItem(at: root) }
        let est = ClaudeSessionScanner.estimate(now: now, projectsDir: root)
        #expect(est.totalsByModel["claude-opus-4-7"]?.inputTokens == 100)
        #expect(est.totalsByModel["claude-opus-4-7"]?.outputTokens == 50)
        #expect(est.totalsByModel["claude-opus-4-7"]?.cacheReadTokens == 1_000)
    }

    @Test("duplicates with differing usage keep the line with the larger output")
    func duplicate_key_keeps_larger_output() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let small = Self.keyedLine(timestamp: ts, messageId: "msg_B", requestId: "req_B",
                                   input: 100, output: 10, cacheRead: 1_000)
        let large = Self.keyedLine(timestamp: ts, messageId: "msg_B", requestId: "req_B",
                                   input: 100, output: 80, cacheRead: 1_000)
        // Larger-first and larger-last must both settle on the larger output.
        let root = try Self.makeProjects(["a.jsonl": [small, large],
                                          "b.jsonl": [
                                              Self.keyedLine(timestamp: ts, messageId: "msg_C", requestId: "req_C",
                                                             model: "claude-haiku-4-5", input: 7, output: 90),
                                              Self.keyedLine(timestamp: ts, messageId: "msg_C", requestId: "req_C",
                                                             model: "claude-haiku-4-5", input: 7, output: 5),
                                          ]])
        defer { try? FileManager.default.removeItem(at: root) }
        let est = ClaudeSessionScanner.estimate(now: now, projectsDir: root)
        #expect(est.totalsByModel["claude-opus-4-7"]?.outputTokens == 80)
        #expect(est.totalsByModel["claude-opus-4-7"]?.inputTokens == 100)
        #expect(est.totalsByModel["claude-haiku-4-5"]?.outputTokens == 90)
        #expect(est.totalsByModel["claude-haiku-4-5"]?.inputTokens == 7)
    }

    @Test("the same key in two different files counts once")
    func duplicate_key_across_files_counts_once() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let line = Self.keyedLine(timestamp: ts, messageId: "msg_D", requestId: "req_D",
                                  input: 100, output: 50)
        let root = try Self.makeProjects(["orig.jsonl": [line], "resumed.jsonl": [line]])
        defer { try? FileManager.default.removeItem(at: root) }
        let est = ClaudeSessionScanner.estimate(now: now, projectsDir: root)
        #expect(est.totalsByModel["claude-opus-4-7"]?.inputTokens == 100)
        #expect(est.totalsByModel["claude-opus-4-7"]?.outputTokens == 50)
    }

    /// TEST-MAE-001. The replaying file (`orig`) carries a key only it has
    /// (`msg_U`) next to one it shares with the re-scanned file (`msg_E`). A
    /// memo that stored no keyed records would lose `msg_U` on replay (a total
    /// of 100/50); one that folded replayed records straight into the totals
    /// instead of merging them would count `msg_E` twice (210/105). Only the
    /// correct replay yields 110/55. The earlier version of this test used a
    /// single shared record, so dropping `keyed` from the memo still passed.
    @Test("cross-file dedup holds when one file replays from the memo")
    func duplicate_key_across_files_with_memo_replay() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let shared = Self.keyedLine(timestamp: ts, messageId: "msg_E", requestId: "req_E",
                                    input: 100, output: 50)
        let onlyInOrig = Self.keyedLine(timestamp: ts, messageId: "msg_U", requestId: "req_U",
                                        input: 10, output: 5)
        let root = try Self.makeProjects(["orig.jsonl": [shared, onlyInOrig],
                                          "resumed.jsonl": [shared]])
        defer { try? FileManager.default.removeItem(at: root) }
        let memo = ScanMemo()
        _ = ClaudeSessionScanner.estimate(now: now, projectsDir: root, memo: memo)
        // Grow one file so it re-scans while the other replays from the memo.
        let resumed = root.appendingPathComponent("proj/resumed.jsonl")
        let handle = try FileHandle(forWritingTo: resumed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"role":"user","content":"hi"}"# + "\n").utf8))
        try handle.close()
        let est = ClaudeSessionScanner.estimate(now: now, projectsDir: root, memo: memo)
        #expect(est.totalsByModel["claude-opus-4-7"]?.inputTokens == 110)
        #expect(est.totalsByModel["claude-opus-4-7"]?.outputTokens == 55)
    }

    /// A long-context Haiku 5.5 record does not fit `ScanMemo.KeyedUsage`'s
    /// compact shape and is stored boxed. It must survive dedup (larger
    /// output wins) and a memo replay with its surcharge subsets intact.
    @Test("a long-context Haiku 5.5 record survives dedup and memo replay")
    func haiku55_long_record_dedup_and_memo_replay() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        func line(output: Int) -> String {
            Self.keyedLine(timestamp: ts, messageId: "msg_H", requestId: "req_H",
                           model: "claude-haiku-5-5", input: 150_000, output: output)
        }
        let root = try Self.makeProjects(["orig.jsonl": [line(output: 3), line(output: 7)],
                                          "resumed.jsonl": [line(output: 7)]])
        defer { try? FileManager.default.removeItem(at: root) }
        let memo = ScanMemo()
        _ = ClaudeSessionScanner.estimate(now: now, projectsDir: root, memo: memo)
        let resumed = root.appendingPathComponent("proj/resumed.jsonl")
        let handle = try FileHandle(forWritingTo: resumed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"role":"user","content":"hi"}"# + "\n").utf8))
        try handle.close()
        let est = ClaudeSessionScanner.estimate(now: now, projectsDir: root, memo: memo)
        let u = est.totalsByModel["claude-haiku-5-5"]
        #expect(u?.inputTokens == 150_000)
        #expect(u?.outputTokens == 7)
        #expect(u?.longContextInputTokens == 150_000)
        #expect(u?.longContextOutputTokens == 7)
        // Whole request at the >100K row: 0.15M × $0.50 + 7 × $2.50/M.
        let usd = est.modelBreakdownLast7Days["claude-haiku-5-5"] ?? -1
        #expect(abs(usd - 0.075_017_5) < 1e-12)
    }

    /// LEAK-FAN-002. A cancelled scan breaks out of the walk having visited
    /// only some files. Pruning the memo to that partial set evicted every
    /// entry it had not reached, so the next scan re-parsed everything cold.
    @Test("a cancelled scan does not evict memo entries it never reached")
    func cancelled_scan_keeps_memo() async throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let root = try Self.makeProjects([
            "a.jsonl": [Self.keyedLine(timestamp: ts, messageId: "m1", requestId: "r1", input: 1)],
            "b.jsonl": [Self.keyedLine(timestamp: ts, messageId: "m2", requestId: "r2", input: 1)],
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let memo = ScanMemo()
        _ = ClaudeSessionScanner.estimate(now: now, projectsDir: root, memo: memo)
        #expect(memo.count == 2)
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = ClaudeSessionScanner.estimate(now: now, projectsDir: root, memo: memo)
        }.value
        #expect(memo.count == 2)
    }

    /// BUG-ART-006. "Last 7 days" is today plus the six previous local days.
    /// The old cutoff (`startOfToday - 7 * 86_400`) kept a record one second
    /// before that window, i.e. up to eight calendar days.
    @Test("the 7-day window starts at local midnight six days before today")
    func seven_day_window_boundary() throws {
        let cal = Calendar.current
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 18, hour: 12)))
        let windowStart = try #require(cal.date(byAdding: .day, value: -6,
                                                to: cal.startOfDay(for: now)))
        let iso = ISO8601DateFormatter()
        let inside = Self.keyedLine(timestamp: iso.string(from: windowStart.addingTimeInterval(1)),
                                    messageId: nil, requestId: nil, input: 1_000_000)
        let outside = Self.keyedLine(timestamp: iso.string(from: windowStart.addingTimeInterval(-1)),
                                     messageId: nil, requestId: nil, input: 2_000_000)
        let both = try Self.makeProjects(["s.jsonl": [inside, outside]])
        let insideOnly = try Self.makeProjects(["s.jsonl": [inside]])
        defer {
            try? FileManager.default.removeItem(at: both)
            try? FileManager.default.removeItem(at: insideOnly)
        }
        let est = ClaudeSessionScanner.estimate(now: now, projectsDir: both, memo: ScanMemo())
        let reference = ClaudeSessionScanner.estimate(now: now, projectsDir: insideOnly, memo: ScanMemo())
        #expect(reference.usdLast7Days > 0)
        #expect(est.usdLast7Days == reference.usdLast7Days)
    }

    @Test("lines missing message.id or requestId are still counted, each one")
    func lines_without_ids_are_counted() throws {
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let noIds = Self.keyedLine(timestamp: ts, messageId: nil, requestId: nil, input: 100, output: 50)
        let onlyMsg = Self.keyedLine(timestamp: ts, messageId: "msg_F", requestId: nil, input: 10, output: 5)
        let onlyReq = Self.keyedLine(timestamp: ts, messageId: nil, requestId: "req_F", input: 1, output: 1)
        let root = try Self.makeProjects(["s.jsonl": [noIds, noIds, onlyMsg, onlyMsg, onlyReq]])
        defer { try? FileManager.default.removeItem(at: root) }
        let est = ClaudeSessionScanner.estimate(now: now, projectsDir: root)
        #expect(est.totalsByModel["claude-opus-4-7"]?.inputTokens == 221)
        #expect(est.totalsByModel["claude-opus-4-7"]?.outputTokens == 111)
    }

    @Test("scan() dedups a repeated key within the data it is given")
    func scan_dedups_within_data() {
        let startOfToday = Date(timeIntervalSince1970: 1_764_000_000)
        let iso = ISO8601DateFormatter().string(from: startOfToday.addingTimeInterval(60))
        let line = Self.keyedLine(timestamp: iso, messageId: "msg_G", requestId: "req_G",
                                  input: 100, output: 50)
        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var unparseable = 0
        ClaudeSessionScanner.scan(data: Data(([line, line].joined(separator: "\n") + "\n").utf8),
                                  startOfToday: startOfToday,
                                  sevenDaysAgo: startOfToday.addingTimeInterval(-7 * 86_400),
                                  totalsToday: &today, totalsLast7: &week,
                                  unparseableTimestamps: &unparseable)
        #expect(today["claude-opus-4-7"]?.inputTokens == 100)
        #expect(week["claude-opus-4-7"]?.outputTokens == 50)
    }

    @Test("scan() with dailyTotals buckets usage into the appropriate calendar days")
    func scan_with_daily_totals_buckets() {
        let cal = Calendar.current
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        let startOfToday = cal.startOfDay(for: now)
        let sevenDaysAgo = cal.date(byAdding: .day, value: -6, to: startOfToday)!
        let todayISO = ISO8601DateFormatter().string(from: startOfToday.addingTimeInterval(3600))
        let threeDaysAgo = cal.date(byAdding: .day, value: -3, to: startOfToday)!
        let threeDaysAgoISO = ISO8601DateFormatter().string(from: threeDaysAgo.addingTimeInterval(3600))

        let lineToday = Self.keyedLine(timestamp: todayISO, messageId: "msg_today", requestId: "req_today",
                                       input: 100, output: 50)
        let lineThreeDaysAgo = Self.keyedLine(timestamp: threeDaysAgoISO, messageId: "msg_3d", requestId: "req_3d",
                                              input: 200, output: 100)
        let data = Data(([lineToday, lineThreeDaysAgo].joined(separator: "\n") + "\n").utf8)

        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var daily: [[String: ModelUsage]] = Array(repeating: [:], count: 7)
        var unparseable = 0
        ClaudeSessionScanner.scan(data: data,
                                  startOfToday: startOfToday,
                                  sevenDaysAgo: sevenDaysAgo,
                                  totalsToday: &today,
                                  totalsLast7: &week,
                                  dailyTotals: &daily,
                                  unparseableTimestamps: &unparseable)

        #expect(today["claude-opus-4-7"]?.inputTokens == 100)
        #expect(week["claude-opus-4-7"]?.inputTokens == 300)
        #expect(daily.count == 7)
        // Slot 6 is today
        #expect(daily[6]["claude-opus-4-7"]?.inputTokens == 100)
        // Slot 3 is 3 days ago (6 - 3 = 3)
        #expect(daily[3]["claude-opus-4-7"]?.inputTokens == 200)
        // Other slots are empty
        #expect(daily[0].isEmpty)
        #expect(daily[1].isEmpty)
        #expect(daily[2].isEmpty)
        #expect(daily[4].isEmpty)
        #expect(daily[5].isEmpty)
    }
}
