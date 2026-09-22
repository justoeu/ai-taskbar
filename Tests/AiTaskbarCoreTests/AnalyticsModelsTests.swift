import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("Analytics domain models & UsageHistoryStore 90-day retention")
struct AnalyticsModelsTests {
    @Test("AnalyticsTimeframe cases exist and have matching id")
    func timeframe_cases() {
        #expect(AnalyticsTimeframe.allCases.count == 3)
        #expect(AnalyticsTimeframe.daily.rawValue == "daily")
        #expect(AnalyticsTimeframe.weekly.rawValue == "weekly")
        #expect(AnalyticsTimeframe.monthly.rawValue == "monthly")
        #expect(AnalyticsTimeframe.daily.id == "daily")
    }

    @Test("PeakDayRecord initializes properly and checks historical peak")
    func peak_day_record() {
        let now = Date()
        let record = PeakDayRecord(date: now, costUSD: 42.10, utilizationPercent: 84.5, isHistoricalPeak: true)
        #expect(record.date == now)
        #expect(record.costUSD == 42.10)
        #expect(record.utilizationPercent == 84.5)
        #expect(record.isHistoricalPeak)
    }

    @Test("VendorAnalyticsSummary and VendorShare hold values")
    func vendor_summary_and_share() {
        let share = VendorShare(vendor: .anthropic, percentage: 45.0, costUSD: 134.50, colorIndex: 1)
        #expect(share.id == .anthropic)
        #expect(share.percentage == 45.0)
        #expect(share.costUSD == 134.50)

        let summary = VendorAnalyticsSummary(
            vendor: .anthropic,
            planLabel: "Pro",
            totalCostUSD: 134.50,
            totalUsagePercent: 45.0,
            sessionCount: 12,
            peakDay: nil,
            costByModel: ["claude-opus-4-7": 100.0, "claude-sonnet-4-6": 34.50],
            deltaPreviousPeriodPercent: 12.5
        )
        #expect(summary.id == .anthropic)
        #expect(summary.vendor == .anthropic)
        #expect(summary.sessionCount == 12)
        #expect(summary.deltaPreviousPeriodPercent == 12.5)
        #expect(summary.costByModel.count == 2)
    }

    @Test("GlobalAnalyticsSnapshot aggregates top-level values")
    func global_snapshot() {
        let snap = GlobalAnalyticsSnapshot(
            timeframe: .weekly,
            compareWithPrevious: true,
            totalCostUSD: 500.0,
            vendorShares: [],
            vendorSummaries: []
        )
        #expect(snap.timeframe == .weekly)
        #expect(snap.compareWithPrevious)
        #expect(snap.totalCostUSD == 500.0)
    }

    @Test("UsageHistoryStore defaultRetention is 90 days")
    func store_retention_90_days() {
        #expect(UsageHistoryStore.defaultRetention == 90 * 86_400)
    }

    @Test("UsageHistoryStore load(between:and:) filters both bounds")
    func store_load_between() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-range-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = UsageHistoryStore(vendor: .anthropic, baseDir: tmp)
        store.append(maxUtilization: 10, at: Date(timeIntervalSince1970: 100))
        store.append(maxUtilization: 20, at: Date(timeIntervalSince1970: 200))
        store.append(maxUtilization: 30, at: Date(timeIntervalSince1970: 300))
        store.append(maxUtilization: 40, at: Date(timeIntervalSince1970: 400))

        let inRange = store.load(
            between: Date(timeIntervalSince1970: 150),
            and: Date(timeIntervalSince1970: 350)
        )
        #expect(inRange.count == 2)
        #expect(inRange.first?.max == 20)
        #expect(inRange.last?.max == 30)
    }
}
