import Testing
import AiTaskbarTestSupport
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
}
