import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("AnalyticsAggregator")
struct AnalyticsAggregatorTests {
    @Test("empty inputs produce zero-cost global snapshot")
    func empty_aggregate() {
        let snapshot = AnalyticsAggregator.aggregate(
            timeframe: .daily,
            compareWithPrevious: false,
            now: Date(),
            histories: [:],
            estimates: [:],
            snapshots: [:]
        )
        #expect(snapshot.totalCostUSD == 0)
        #expect(snapshot.vendorShares.isEmpty)
        #expect(snapshot.vendorSummaries.isEmpty)
        #expect(snapshot.timeframe == .daily)
    }

    @Test("aggregates multiple vendors into shares and summaries")
    func multi_vendor_aggregate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let anthropicEstimate = CostEstimate(
            usdToday: 10.0,
            usdLast7Days: 50.0,
            modelBreakdownToday: ["claude-sonnet-4-6": 10.0],
            modelBreakdownLast7Days: ["claude-sonnet-4-6": 50.0]
        )
        let openaiEstimate = CostEstimate(
            usdToday: 30.0,
            usdLast7Days: 150.0,
            modelBreakdownToday: ["gpt-5.6-sol": 30.0],
            modelBreakdownLast7Days: ["gpt-5.6-sol": 150.0]
        )

        let snapshot = AnalyticsAggregator.aggregate(
            timeframe: .daily,
            compareWithPrevious: false,
            now: now,
            histories: [:],
            estimates: [
                .anthropic: anthropicEstimate,
                .openai: openaiEstimate
            ],
            snapshots: [
                .anthropic: .anthropic(AnthropicSnapshot(planLabel: "Max 5x")),
                .openai: .openai(OpenAISnapshot(planLabel: "Team"))
            ]
        )

        #expect(snapshot.totalCostUSD == 40.0)
        #expect(snapshot.vendorShares.count == 2)
        // OpenAI was $30 out of $40 (75%)
        let openaiShare = snapshot.vendorShares.first(where: { $0.vendor == .openai })
        #expect(openaiShare?.costUSD == 30.0)
        #expect(openaiShare?.percentage == 75.0)

        // Anthropic was $10 out of $40 (25%)
        let anthropicShare = snapshot.vendorShares.first(where: { $0.vendor == .anthropic })
        #expect(anthropicShare?.costUSD == 10.0)
        #expect(anthropicShare?.percentage == 25.0)

        // Vendor summaries
        #expect(snapshot.vendorSummaries.count == 2)
        let anthropicSummary = snapshot.vendorSummaries.first(where: { $0.vendor == .anthropic })
        #expect(anthropicSummary?.planLabel == "Max 5x")
        #expect(anthropicSummary?.totalCostUSD == 10.0)
        #expect(anthropicSummary?.costByModel["claude-sonnet-4-6"] == 10.0)
    }

    @Test("weekly timeframe aggregates 7-day costs")
    func weekly_timeframe_aggregate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let anthropicEstimate = CostEstimate(
            usdToday: 5.0,
            usdLast7Days: 45.0,
            modelBreakdownToday: [:],
            modelBreakdownLast7Days: ["claude-opus-4-7": 45.0]
        )

        let snapshot = AnalyticsAggregator.aggregate(
            timeframe: .weekly,
            compareWithPrevious: false,
            now: now,
            histories: [:],
            estimates: [.anthropic: anthropicEstimate],
            snapshots: [:]
        )

        #expect(snapshot.totalCostUSD == 45.0)
        let summary = snapshot.vendorSummaries.first
        #expect(summary?.totalCostUSD == 45.0)
        #expect(summary?.costByModel["claude-opus-4-7"] == 45.0)
    }

    @Test("peak day identification detects the highest utilization day with historical peak flag")
    func peak_day_detection() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let day1 = today.addingTimeInterval(-86_400 * 3)
        let day2 = today.addingTimeInterval(-86_400 * 2) // Peak day
        let day3 = today.addingTimeInterval(-86_400 * 1)

        let samples = [
            UsageHistoryStore.Sample(at: day1.timeIntervalSince1970 + 3600, max: 20.0),
            UsageHistoryStore.Sample(at: day1.timeIntervalSince1970 + 7200, max: 40.0),
            UsageHistoryStore.Sample(at: day2.timeIntervalSince1970 + 3600, max: 85.0), // Record
            UsageHistoryStore.Sample(at: day3.timeIntervalSince1970 + 3600, max: 50.0),
            UsageHistoryStore.Sample(at: today.timeIntervalSince1970 + 3600, max: 30.0),
        ]

        let peak = AnalyticsAggregator.computePeakDay(from: samples, now: today)
        #expect(peak != nil)
        #expect(peak?.utilizationPercent == 85.0)
        #expect(peak?.isHistoricalPeak == true)
    }

    @Test("delta comparison calculates percent change")
    func delta_comparison() {
        let delta = AnalyticsAggregator.computeDelta(current: 120.0, previous: 100.0)
        #expect(delta == 20.0)

        let negativeDelta = AnalyticsAggregator.computeDelta(current: 80.0, previous: 100.0)
        #expect(negativeDelta == -20.0)

        let zeroPrev = AnalyticsAggregator.computeDelta(current: 50.0, previous: 0.0)
        #expect(zeroPrev == nil)
    }
}
