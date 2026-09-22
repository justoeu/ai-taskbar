import Foundation

public enum AnalyticsTimeframe: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }
}

public struct PeakDayRecord: Sendable, Equatable {
    public let date: Date
    public let costUSD: Double
    public let utilizationPercent: Double
    public let isHistoricalPeak: Bool

    public init(date: Date, costUSD: Double, utilizationPercent: Double, isHistoricalPeak: Bool = false) {
        self.date = date
        self.costUSD = costUSD
        self.utilizationPercent = utilizationPercent
        self.isHistoricalPeak = isHistoricalPeak
    }
}

public struct VendorAnalyticsSummary: Sendable, Equatable, Identifiable {
    public var id: VendorId { vendor }
    public let vendor: VendorId
    public let planLabel: String?
    public let totalCostUSD: Double
    public let totalUsagePercent: Double
    public let sessionCount: Int
    public let peakDay: PeakDayRecord?
    public let costByModel: [String: Double]
    public let usageHistory: [UsageHistoryStore.Sample]
    public let deltaPreviousPeriodPercent: Double?

    public init(vendor: VendorId,
                planLabel: String? = nil,
                totalCostUSD: Double,
                totalUsagePercent: Double,
                sessionCount: Int = 0,
                peakDay: PeakDayRecord? = nil,
                costByModel: [String: Double] = [:],
                usageHistory: [UsageHistoryStore.Sample] = [],
                deltaPreviousPeriodPercent: Double? = nil) {
        self.vendor = vendor
        self.planLabel = planLabel
        self.totalCostUSD = totalCostUSD
        self.totalUsagePercent = totalUsagePercent
        self.sessionCount = sessionCount
        self.peakDay = peakDay
        self.costByModel = costByModel
        self.usageHistory = usageHistory
        self.deltaPreviousPeriodPercent = deltaPreviousPeriodPercent
    }
}

public struct VendorShare: Sendable, Equatable, Identifiable {
    public var id: VendorId { vendor }
    public let vendor: VendorId
    public let percentage: Double
    public let costUSD: Double
    public let colorIndex: Int

    public init(vendor: VendorId, percentage: Double, costUSD: Double, colorIndex: Int = 0) {
        self.vendor = vendor
        self.percentage = percentage
        self.costUSD = costUSD
        self.colorIndex = colorIndex
    }
}

public struct GlobalAnalyticsSnapshot: Sendable, Equatable {
    public let timeframe: AnalyticsTimeframe
    public let compareWithPrevious: Bool
    public let totalCostUSD: Double
    public let vendorShares: [VendorShare]
    public let vendorSummaries: [VendorAnalyticsSummary]
    public let computedAt: Date

    public init(timeframe: AnalyticsTimeframe = .daily,
                compareWithPrevious: Bool = false,
                totalCostUSD: Double,
                vendorShares: [VendorShare] = [],
                vendorSummaries: [VendorAnalyticsSummary] = [],
                computedAt: Date = Date()) {
        self.timeframe = timeframe
        self.compareWithPrevious = compareWithPrevious
        self.totalCostUSD = totalCostUSD
        self.vendorShares = vendorShares
        self.vendorSummaries = vendorSummaries
        self.computedAt = computedAt
    }
}
