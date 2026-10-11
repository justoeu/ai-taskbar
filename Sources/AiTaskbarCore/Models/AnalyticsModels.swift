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
    /// Real sessions, from a session counter (Gemini/Antigravity, Grok CLI).
    /// Zero for vendors that have none — never a model count in disguise.
    public let sessionCount: Int
    /// Distinct models with cost-window usage (the `costByModel` rows).
    public let modelCount: Int
    /// False when no cost source covers the timeframe (Month): the scanners
    /// keep today and the last 7 days only, so `totalCostUSD` is 0 and
    /// `costByModel` empty by construction, not because nothing was spent.
    public let isCostAvailable: Bool
    public let peakDay: PeakDayRecord?
    public let costByModel: [String: Double]
    public let usageHistory: [UsageHistoryStore.Sample]
    public let deltaPreviousPeriodPercent: Double?
    public let lifetimeCostUSD: Double?
    /// Tokens and requests in the timeframe, from a vendor that reports them
    /// (TypeSafe's console). Nil when no such source covers the timeframe.
    public let activity: VendorActivity?
    /// Per-model daily usage for the 7-day window (scanners: Claude, Codex).
    public let dailyModelUsage: [DailyModelUsage]

    public init(vendor: VendorId,
                planLabel: String? = nil,
                totalCostUSD: Double,
                totalUsagePercent: Double,
                sessionCount: Int = 0,
                modelCount: Int = 0,
                isCostAvailable: Bool = true,
                peakDay: PeakDayRecord? = nil,
                costByModel: [String: Double] = [:],
                usageHistory: [UsageHistoryStore.Sample] = [],
                deltaPreviousPeriodPercent: Double? = nil,
                lifetimeCostUSD: Double? = nil,
                activity: VendorActivity? = nil,
                dailyModelUsage: [DailyModelUsage] = []) {
        self.vendor = vendor
        self.planLabel = planLabel
        self.totalCostUSD = totalCostUSD
        self.totalUsagePercent = totalUsagePercent
        self.sessionCount = sessionCount
        self.modelCount = modelCount
        self.isCostAvailable = isCostAvailable
        self.peakDay = peakDay
        self.costByModel = costByModel
        self.usageHistory = usageHistory
        self.deltaPreviousPeriodPercent = deltaPreviousPeriodPercent
        self.lifetimeCostUSD = lifetimeCostUSD
        self.activity = activity
        self.dailyModelUsage = dailyModelUsage
    }

    /// True when the card may say "no recent usage": nothing in the
    /// timeframe shows activity. Evidence of idleness requires a cost source
    /// for the timeframe — on Month (`isCostAvailable == false`) the cost is 0
    /// by construction, so a pay-per-token vendor with no quota window would
    /// otherwise be called idle while it spent money this week (BUG-MAE-002).
    public var showsNoRecentUsage: Bool {
        isCostAvailable
            && costByModel.isEmpty
            && sessionCount == 0
            && peakDay == nil
            && (lifetimeCostUSD ?? 0) == 0
            && totalCostUSD <= 0.0001
            && totalUsagePercent <= 0.0001
            && !(activity?.hasActivity ?? false)
            && dailyModelUsage.allSatisfy { $0.usageByModel.isEmpty }
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
    public let comparisonOffset: Int
    public let totalCostUSD: Double
    public let vendorShares: [VendorShare]
    public let vendorSummaries: [VendorAnalyticsSummary]
    public let computedAt: Date
    /// See `VendorAnalyticsSummary.isCostAvailable`.
    public let isCostAvailable: Bool

    public init(timeframe: AnalyticsTimeframe = .daily,
                compareWithPrevious: Bool = false,
                comparisonOffset: Int = 1,
                totalCostUSD: Double,
                vendorShares: [VendorShare] = [],
                vendorSummaries: [VendorAnalyticsSummary] = [],
                computedAt: Date = Date(),
                isCostAvailable: Bool = true) {
        self.timeframe = timeframe
        self.compareWithPrevious = compareWithPrevious
        self.comparisonOffset = comparisonOffset
        self.totalCostUSD = totalCostUSD
        self.vendorShares = vendorShares
        self.vendorSummaries = vendorSummaries
        self.computedAt = computedAt
        self.isCostAvailable = isCostAvailable
    }
}

/// Token and request counts for one analytics timeframe, with a zero-filled
/// series (hours of today for Day, the 7 days for Week) for the bar chart.
public struct VendorActivity: Sendable, Equatable {
    public enum Granularity: Sendable, Equatable { case hour, day }

    public struct Point: Sendable, Equatable, Identifiable {
        public var id: Date { start }
        public let start: Date
        public let tokens: Int
        public let requests: Int

        public init(start: Date, tokens: Int, requests: Int) {
            self.start = start
            self.tokens = tokens
            self.requests = requests
        }
    }

    public let inputTokens: Int
    public let outputTokens: Int
    public let requests: Int
    public let granularity: Granularity
    public let series: [Point]

    public init(inputTokens: Int, outputTokens: Int, requests: Int,
                granularity: Granularity, series: [Point]) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.requests = requests
        self.granularity = granularity
        self.series = series
    }

    public var hasActivity: Bool { requests > 0 || inputTokens > 0 || outputTokens > 0 }
}
