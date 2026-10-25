import Testing
import Foundation
@testable import AiTaskbarApp
import AiTaskbarCore

/// opencode is a client, not a vendor: its usage must never add dollars to
/// the billing vendor's own Analytics total (OpenAI rides a subscription;
/// xAI/Z.AI/Gemini totals must not be restated). Tokens still merge.
@Suite("AnalyticsOpencodeMerge")
struct AnalyticsOpencodeMergeTests {
    private static func scan(model: String, tokens: Int, reportedCost: Double = 0) -> OpencodeScan {
        var s = OpencodeScan()
        s.todayByModel[model] = ModelUsage(inputTokens: tokens)
        s.last7DaysByModel[model] = ModelUsage(inputTokens: tokens)
        if reportedCost > 0 {
            s.costTodayByModel[model] = reportedCost
            s.costLast7DaysByModel[model] = reportedCost
        }
        return s
    }

    @Test("opencode OpenAI usage adds no dollars to the OpenAI estimate")
    func openai_dollars_not_added() {
        let merged = AnalyticsStore.mergingOpencode(
            [.openai: CostEstimate(usdToday: 3, usdLast7Days: 12)],
            opencode: [.openai: Self.scan(model: "gpt-5.6-sol", tokens: 1_000_000)])
        #expect(merged[.openai]?.usdLast7Days == 12)
        #expect(merged[.openai]?.usdToday == 3)
    }

    @Test("opencode OpenAI tokens still merge into totalsByModel")
    func openai_tokens_merged() {
        let merged = AnalyticsStore.mergingOpencode(
            [.openai: CostEstimate(usdToday: 3, usdLast7Days: 12)],
            opencode: [.openai: Self.scan(model: "gpt-5.6-sol", tokens: 1_000_000)])
        #expect(merged[.openai]?.totalsByModel["gpt-5.6-sol"]?.inputTokens == 1_000_000)
    }

    @Test("opencode Z.AI usage, even with an opencode-reported cost, adds no dollars")
    func zai_dollars_not_added() {
        let merged = AnalyticsStore.mergingOpencode(
            [.zai: CostEstimate(usdToday: 3, usdLast7Days: 12)],
            opencode: [.zai: Self.scan(model: "glm-5.2", tokens: 1_000_000, reportedCost: 7.5)])
        #expect(merged[.zai]?.usdLast7Days == 12)
        #expect(merged[.zai]?.usdToday == 3)
    }

    @Test("opencode-only vendor gets a tokens-only estimate with zero dollars")
    func opencode_only_vendor_zero_dollars() {
        let merged = AnalyticsStore.mergingOpencode(
            [:],
            opencode: [.gemini: Self.scan(model: "gemini-2.5-pro", tokens: 1_000_000, reportedCost: 4)])
        #expect(merged[.gemini]?.usdLast7Days == 0)
        #expect(merged[.gemini]?.usdToday == 0)
        #expect(merged[.gemini]?.totalsByModel["gemini-2.5-pro"]?.inputTokens == 1_000_000)
    }

    /// The popover footer lists opencode models in their own section, with
    /// the cost opencode recorded (or tokens for subscription traffic).
    /// Analytics cannot show that cost without adding it to the vendor total,
    /// so it leaves the model out rather than contradict the footer with a
    /// fabricated $0.00 row. Tokens still merge (see above).
    @Test("opencode models add no $0 row to an existing vendor's 7-day breakdown")
    func no_zero_row_last7_existing_vendor() {
        let merged = AnalyticsStore.mergingOpencode(
            [.xai: CostEstimate(usdToday: 1, usdLast7Days: 4,
                                modelBreakdownToday: ["grok-5": 1],
                                modelBreakdownLast7Days: ["grok-5": 4])],
            opencode: [.xai: Self.scan(model: "grok-code-fast", tokens: 1_000, reportedCost: 2)])
        #expect(merged[.xai]?.modelBreakdownLast7Days == ["grok-5": 4])
    }

    @Test("opencode models add no $0 row to an existing vendor's today breakdown")
    func no_zero_row_today_existing_vendor() {
        let merged = AnalyticsStore.mergingOpencode(
            [.xai: CostEstimate(usdToday: 1, usdLast7Days: 4,
                                modelBreakdownToday: ["grok-5": 1],
                                modelBreakdownLast7Days: ["grok-5": 4])],
            opencode: [.xai: Self.scan(model: "grok-code-fast", tokens: 1_000, reportedCost: 2)])
        #expect(merged[.xai]?.modelBreakdownToday == ["grok-5": 1])
    }

    @Test("opencode-only vendor gets no $0 row in its 7-day breakdown")
    func no_zero_rows_opencode_only_vendor_last7() {
        let merged = AnalyticsStore.mergingOpencode(
            [:],
            opencode: [.gemini: Self.scan(model: "gemini-2.5-pro", tokens: 1_000, reportedCost: 4)])
        #expect(merged[.gemini]?.modelBreakdownLast7Days == [:])
    }

    @Test("opencode-only vendor gets no $0 row in its today breakdown")
    func no_zero_rows_opencode_only_vendor_today() {
        let merged = AnalyticsStore.mergingOpencode(
            [:],
            opencode: [.gemini: Self.scan(model: "gemini-2.5-pro", tokens: 1_000, reportedCost: 4)])
        #expect(merged[.gemini]?.modelBreakdownToday == [:])
    }

    // MARK: per-day series (Analytics chart)

    private static let days: [Date] = CostWindow(now: Date()).calendarDays()

    private static func daily(_ model: String, tokensPerDay: [Int], cost: Double = 0) -> [DailyModelUsage] {
        zip(days, tokensPerDay).map { day, tokens in
            DailyModelUsage(date: day,
                            usageByModel: tokens > 0 ? [model: ModelUsage(inputTokens: tokens)] : [:],
                            costByModel: tokens > 0 && cost > 0 ? [model: cost] : [:])
        }
    }

    @Test("a vendor seen only through opencode gets opencode's daily series")
    func opencode_only_vendor_gets_daily_series() {
        var s = Self.scan(model: "glm-5.3", tokens: 70)
        s.daily = Self.daily("glm-5.3", tokensPerDay: [10, 0, 0, 0, 0, 50, 10])
        let merged = AnalyticsStore.mergingOpencode([:], opencode: [.zai: s])
        let series = merged[.zai]?.dailyUsage ?? []
        #expect(series.count == 7)
        #expect(series[5].totalTokens == 50)
        #expect(series[5].totalCostUSD == 0)
    }

    @Test("merging opencode keeps the scanner's daily series (it used to be dropped)")
    func merge_keeps_scanner_daily_series() {
        let scanner = CostEstimate(usdToday: 1, usdLast7Days: 7,
                                   dailyUsage: Self.daily("gemini-4-argon", tokensPerDay: [0, 0, 0, 0, 0, 0, 100], cost: 2))
        var s = Self.scan(model: "gemini-4-argon", tokens: 30)
        s.daily = Self.daily("gemini-4-argon", tokensPerDay: [0, 0, 0, 0, 0, 0, 30])
        let merged = AnalyticsStore.mergingOpencode([.gemini: scanner], opencode: [.gemini: s])
        let today = merged[.gemini]?.dailyUsage.last
        #expect(merged[.gemini]?.dailyUsage.count == 7)
        #expect(today?.totalTokens == 130)       // tokens add up
        #expect(today?.totalCostUSD == 2)        // opencode dollars never added
    }

    @Test("mergingDaily with one side empty returns the other side")
    func merging_daily_one_side_empty() {
        let series = Self.daily("m", tokensPerDay: [1, 2, 3, 4, 5, 6, 7])
        #expect(AnalyticsStore.mergingDaily([], opencode: series) == series)
        #expect(AnalyticsStore.mergingDaily(series, opencode: []) == series)
    }
}
