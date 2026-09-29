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
}
