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
                                      cacheRead: Int = 0) -> String {
        #"""
        {"timestamp":"\#(timestamp)","message":{"role":"assistant","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheCreate),"cache_read_input_tokens":\#(cacheRead)}}}
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
        #expect(est.note?.contains("No ~/.claude/projects directory.") == true)
    }

    @Test("estimate with empty projectsDir → returns 'no recent sessions' note")
    func estimate_empty_directory_path() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let est = ClaudeSessionScanner.estimate(projectsDir: dir)
        #expect(est.usdToday == 0)
        #expect(est.note?.contains("No recent Claude sessions") == true)
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
}
