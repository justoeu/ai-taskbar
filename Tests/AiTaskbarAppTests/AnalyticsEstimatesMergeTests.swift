import Testing
import Foundation
@testable import AiTaskbarApp
import AiTaskbarCore

/// `AnalyticsStore.defaultEstimates` is the real merge behind the Analytics
/// screen's default `estimatesProvider`. Every figure it produces lands in a
/// slot with a fixed window: `usdToday` or `usdLast7Days`. No vendor snapshot
/// carries a rolling 7-day dollar figure — OpenRouter `/api/v1/activity`
/// covers 30 days, xAI spend is billing-cycle-to-date — so none of them may
/// be written into those slots.
@Suite("AnalyticsEstimatesMerge")
struct AnalyticsEstimatesMergeTests {
    private static let openRouter30Day = VendorSnapshot.openrouter(OpenRouterSnapshot(
        topModels: [
            ModelShare(model: "openai/gpt-4.1", percent: 60, rawUsage: 18),
            ModelShare(model: "google/gemini-2.5-flash", percent: 40, rawUsage: 12)
        ],
        totalUsageUSD: 250))

    private static let xaiCycle = VendorSnapshot.xai(XAISnapshot(
        spentUSD: 40, prepaidUsedUSD: 5, billingCycleLabel: "2026-09"))

    @Test("OpenRouter 30-day activity does not create a 7-day estimate")
    func openrouter_activity_not_in_last7() {
        let merged = AnalyticsStore.defaultEstimates(
            byVendor: [:], opencode: [:], snapshots: [.openrouter: Self.openRouter30Day])
        expectTrue(merged[.openrouter] == nil)
    }

    @Test("OpenRouter 30-day activity does not overwrite an existing 7-day estimate")
    func openrouter_activity_does_not_overwrite_last7() {
        let merged = AnalyticsStore.defaultEstimates(
            byVendor: [.openrouter: CostEstimate(usdToday: 1, usdLast7Days: 7)],
            opencode: [:], snapshots: [.openrouter: Self.openRouter30Day])
        #expect(merged[.openrouter]?.usdLast7Days == 7)
    }

    @Test("OpenRouter 30-day activity adds no rows to the 7-day breakdown")
    func openrouter_activity_adds_no_breakdown_rows() {
        let merged = AnalyticsStore.defaultEstimates(
            byVendor: [.openrouter: CostEstimate(usdToday: 1, usdLast7Days: 7)],
            opencode: [:], snapshots: [.openrouter: Self.openRouter30Day])
        #expect(merged[.openrouter]?.modelBreakdownLast7Days == [:])
    }

    @Test("xAI billing-cycle spend does not create a 7-day estimate")
    func xai_cycle_spend_not_in_last7() {
        let merged = AnalyticsStore.defaultEstimates(
            byVendor: [:], opencode: [:], snapshots: [.xai: Self.xaiCycle])
        expectTrue(merged[.xai] == nil)
    }

    @Test("xAI billing-cycle spend does not raise an existing 7-day estimate")
    func xai_cycle_spend_does_not_raise_last7() {
        let merged = AnalyticsStore.defaultEstimates(
            byVendor: [.xai: CostEstimate(usdToday: 1, usdLast7Days: 3)],
            opencode: [:], snapshots: [.xai: Self.xaiCycle])
        #expect(merged[.xai]?.usdLast7Days == 3)
    }

    @Test("scanner estimates pass through the default merge unchanged")
    func scanner_estimates_pass_through() {
        let claude = CostEstimate(usdToday: 2, usdLast7Days: 9,
                                  modelBreakdownLast7Days: ["claude-opus-5-5": 9],
                                  computedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let merged = AnalyticsStore.defaultEstimates(
            byVendor: [.anthropic: claude], opencode: [:],
            snapshots: [.openrouter: Self.openRouter30Day, .xai: Self.xaiCycle])
        #expect(merged[.anthropic] == claude)
    }
}
