import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("MuseSessionScanner token accumulation (SDD-meta-muse §9)")
struct MuseSessionScannerTests {
    /// One envelope line in the measured 2026-10-12 shape:
    /// {recorded_at (µs), payload:{event:{kind, model, usage}}}.
    private static func usageLine(at date: Date, kind: String = "model_completed",
                                  model: String? = "muse-wonder-full-1.0",
                                  input: Int, output: Int,
                                  cached: Int? = nil, cacheRead: Int? = nil,
                                  cacheWrite: Int = 0, reasoning: Int = 0) -> String {
        let us = Int64(date.timeIntervalSince1970 * 1_000_000)
        let modelJSON = model.map { "\"model\":\"\($0)\"," } ?? ""
        let cachedJSON = cached.map { "\"cached_tokens\":\($0)," } ?? ""
        let readJSON = cacheRead.map { "\"cache_read_tokens\":\($0)," } ?? ""
        return """
        {"recorded_at":\(us),"payload_type":"runtime.session","payload":{"event":{"kind":"\(kind)",\(modelJSON)"usage":{"input_tokens":\(input),"output_tokens":\(output),\(cachedJSON)\(readJSON)"cache_write_tokens":\(cacheWrite),"reasoning_tokens":\(reasoning)}}}}
        """
    }

    private static let now = Date(timeIntervalSince1970: 1_791_900_000)  // fixed anchor

    private func scan(_ lines: [String]) -> (today: [String: ModelUsage], week: [String: ModelUsage]) {
        let window = CostWindow(now: Self.now)
        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var daily: [[String: ModelUsage]] = Array(repeating: [:], count: 7)
        MuseSessionScanner.scan(data: Data((lines.joined(separator: "\n") + "\n").utf8),
                                window: window,
                                totalsToday: &today, totalsLast7: &week, dailyTotals: &daily)
        return (today, week)
    }

    @Test("golden: input includes cache read; reasoning stays inside output")
    func golden_semantics() {
        let cal = Calendar.current
        let t = cal.startOfDay(for: Self.now).addingTimeInterval(3_600)
        // Measured step (SDD §2.1): input 52304, cached/cache_read 48116.
        let (today, _) = scan([Self.usageLine(at: t, input: 52304, output: 465,
                                              cached: 48116, cacheRead: 48116, reasoning: 17)])
        let u = today["muse-wonder-full-1.0"]
        #expect(u?.inputTokens == 4188)          // 52304 - 48116
        #expect(u?.cacheReadTokens == 48116)
        #expect(u?.outputTokens == 465)          // reasoning NOT added
        #expect(u?.totalTokens == 52304 + 465)   // input + output
    }

    @Test("only model_completed and automated_review_completed count")
    func kind_filter() {
        let cal = Calendar.current
        let t = cal.startOfDay(for: Self.now).addingTimeInterval(3_600)
        let lines = [
            Self.usageLine(at: t, kind: "model_completed", input: 100, output: 10),
            Self.usageLine(at: t, kind: "automated_review_completed", input: 200, output: 20),
            Self.usageLine(at: t, kind: "resource_usage_sampled", input: 9999, output: 9999),
            Self.usageLine(at: t, kind: "goal_usage_attribution", input: 8888, output: 8888),
            "{\"children\":[],\"frame_schema_version\":1}",  // frame header line
        ]
        let (today, _) = scan(lines)
        #expect(today["muse-wonder-full-1.0"]?.inputTokens == 300)
        #expect(today["muse-wonder-full-1.0"]?.outputTokens == 30)
    }

    @Test("buckets follow recorded_at, not file or folder date")
    func bucket_by_recorded_at() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Self.now)
        let threeDaysAgo = start.addingTimeInterval(-3 * 86_400 + 3_600)
        let eightDaysAgo = start.addingTimeInterval(-8 * 86_400)
        let (today, week) = scan([
            Self.usageLine(at: start.addingTimeInterval(3_600), input: 100, output: 1),
            Self.usageLine(at: threeDaysAgo, input: 200, output: 2),
            Self.usageLine(at: eightDaysAgo, input: 400, output: 4),
        ])
        #expect(today["muse-wonder-full-1.0"]?.inputTokens == 100)
        #expect(week["muse-wonder-full-1.0"]?.inputTokens == 300)
    }

    @Test("missing model keeps tokens under unknown; cached_tokens fallback")
    func unknown_model_and_cached_fallback() {
        let cal = Calendar.current
        let t = cal.startOfDay(for: Self.now).addingTimeInterval(3_600)
        let (today, _) = scan([Self.usageLine(at: t, model: nil, input: 500, output: 5, cached: 400)])
        #expect(today["unknown"]?.inputTokens == 100)
        #expect(today["unknown"]?.cacheReadTokens == 400)
    }

    @Test("estimate over a temp sessions tree is unpriced with zero USD")
    func estimate_end_to_end() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("muse-scan-\(UUID().uuidString)")
        let day = root.appendingPathComponent("2026/10/12/session-a")
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let cal = Calendar.current
        let t = cal.startOfDay(for: Self.now).addingTimeInterval(3_600)
        let line = Self.usageLine(at: t, input: 1000, output: 100, cached: 250, cacheRead: 250)
        try (line + "\n").write(to: day.appendingPathComponent("session.jsonl"),
                                atomically: true, encoding: .utf8)
        let est = MuseSessionScanner.estimate(now: Self.now, sessionsDir: root, memo: ScanMemo())
        #expect(est.totalsByModel["muse-wonder-full-1.0"]?.totalTokens == 1100)
        #expect(est.usdToday == 0)
        #expect(est.usdLast7Days == 0)
        expectTrue(est.unpricedModelsLast7Days.contains("muse-wonder-full-1.0"))
        // Zero-dollar breakdown rows keep the card footer visible (P-1).
        #expect(est.modelBreakdownToday["muse-wonder-full-1.0"] == 0)
        #expect(est.modelBreakdownLast7Days["muse-wonder-full-1.0"] == 0)
        expectTrue(est.hasDisplayData)
    }

    @Test("missing sessions directory reports honestly, not a measured zero")
    func missing_dir() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-missing-\(UUID().uuidString)")
        let est = MuseSessionScanner.estimate(now: Self.now, sessionsDir: missing, memo: ScanMemo())
        #expect(est.totalsByModel.isEmpty)
        #expect(est.note != nil)
    }
}

@Suite("Paths.museSessionsDir (SDD-meta-muse §9)")
struct MusePathsTests {
    @Test("resolution order: MUSE_SESSIONS_DIR, XDG, default")
    func resolution_order() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(Paths.museSessionsDir(environment: ["MUSE_SESSIONS_DIR": "/x/sessions"],
                                      home: home).path == "/x/sessions")
        #expect(Paths.museSessionsDir(environment: ["XDG_DATA_HOME": "/x/data"],
                                      home: home).path == "/x/data/muse/sessions")
        #expect(Paths.museSessionsDir(environment: [:],
                                      home: home).path == "/Users/test/.local/share/muse/sessions")
    }
}
