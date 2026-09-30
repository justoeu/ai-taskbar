import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("TypeSafe analytics activity")
struct TypeSafeAnalyticsActivityTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let now = ISO8601Parsing.parse("2026-09-30T13:30:00Z")!

    private func snapshot() -> VendorSnapshot {
        let usage = TypeSafeUsage(
            todayInputTokens: 300, todayOutputTokens: 30, todayRequests: 3,
            weekInputTokens: 1_821, weekOutputTokens: 193, weekRequests: 7,
            hourly: [
                TypeSafeUsagePoint(start: ISO8601Parsing.parse("2026-09-29T22:00:00Z")!,
                                   inputTokens: 1_521, outputTokens: 163, requests: 4),
                TypeSafeUsagePoint(start: ISO8601Parsing.parse("2026-09-30T09:00:00Z")!,
                                   inputTokens: 300, outputTokens: 30, requests: 3),
            ],
            daily: [
                TypeSafeUsagePoint(start: ISO8601Parsing.parse("2026-09-29T00:00:00Z")!,
                                   inputTokens: 1_521, outputTokens: 163, requests: 4),
                TypeSafeUsagePoint(start: ISO8601Parsing.parse("2026-09-30T00:00:00Z")!,
                                   inputTokens: 300, outputTokens: 30, requests: 3),
            ])
        return .typesafe(TypeSafeSnapshot(models: [TypeSafeModel(name: "jev-latest")], usage: usage,
                                          console: .connected(expiresAt: nil)))
    }

    @Test("Day: today's totals and 24 hourly slots, zero-filled")
    func daily() throws {
        let a = try #require(AnalyticsAggregator.activity(from: snapshot(), timeframe: .daily, now: now, calendar: utc))
        #expect(a.granularity == .hour)
        #expect(a.inputTokens == 300)
        #expect(a.outputTokens == 30)
        #expect(a.requests == 3)
        #expect(a.series.count == 24)
        #expect(a.series.first?.start == ISO8601Parsing.parse("2026-09-30T00:00:00Z"))
        #expect(a.series[9].tokens == 330)
        #expect(a.series.filter { $0.tokens > 0 }.count == 1)
    }

    @Test("Week: 7-day totals and one slot per day, oldest first")
    func weekly() throws {
        let a = try #require(AnalyticsAggregator.activity(from: snapshot(), timeframe: .weekly, now: now, calendar: utc))
        #expect(a.granularity == .day)
        #expect(a.requests == 7)
        #expect(a.series.count == 7)
        #expect(a.series.first?.start == ISO8601Parsing.parse("2026-09-24T00:00:00Z"))
        #expect(a.series.map(\.requests) == [0, 0, 0, 0, 0, 4, 3])
        #expect(a.series[5].tokens == 1_684)
    }

    @Test("Month has no activity source; other vendors never have one")
    func month_and_others() {
        expectTrue(AnalyticsAggregator.activity(from: snapshot(), timeframe: .monthly, now: now, calendar: utc) == nil)
        let bare = VendorSnapshot.typesafe(TypeSafeSnapshot())
        expectTrue(AnalyticsAggregator.activity(from: bare, timeframe: .daily, now: now, calendar: utc) == nil)
    }

    @Test("activity means the vendor is not idle")
    func not_idle() {
        let g = AnalyticsAggregator.aggregate(timeframe: .weekly, compareWithPrevious: false, now: now,
                                              calendar: utc, snapshots: [.typesafe: snapshot()])
        let s = g.vendorSummaries.first { $0.vendor == .typesafe }
        expectTrue(s?.activity?.requests == 7)
        expectFalse(s?.showsNoRecentUsage ?? true)
        let idle = VendorAnalyticsSummary(vendor: .typesafe, totalCostUSD: 0, totalUsagePercent: 0,
                                          activity: VendorActivity(inputTokens: 0, outputTokens: 0, requests: 0,
                                                                   granularity: .day, series: []))
        #expect(idle.showsNoRecentUsage)
    }

    @Test("a cached usage block without the daily series still decodes")
    func old_cache() throws {
        let json = #"{"todayInputTokens":1,"todayOutputTokens":2,"todayRequests":3,"weekInputTokens":4,"weekOutputTokens":5,"weekRequests":6,"hourly":[]}"#
        let u = try SharedCoders.decoder.decode(TypeSafeUsage.self, from: Data(json.utf8))
        #expect(u.daily.isEmpty)
        #expect(u.weekRequests == 6)
    }
}
