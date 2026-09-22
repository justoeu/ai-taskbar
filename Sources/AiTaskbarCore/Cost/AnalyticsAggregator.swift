import Foundation

public enum AnalyticsAggregator {
    /// Distinct color indices assigned to vendors for donut chart visualization
    public static let vendorColorIndices: [VendorId: Int] = [
        .anthropic: 0, // Orange
        .openai: 1,    // Green
        .xai: 2,       // Purple / Indigo
        .gemini: 3,    // Blue
        .zai: 4,       // Teal / Cyan
        .openrouter: 5,// Pink / Magenta
        .kimi: 6,      // Yellow / Amber
        .deepseek: 7   // Slate / Gray
    ]

    public static func computeDelta(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return ((current - previous) / previous) * 100.0
    }

    public static func computePeakDay(from samples: [UsageHistoryStore.Sample], now: Date = Date()) -> PeakDayRecord? {
        guard !samples.isEmpty else { return nil }
        let calendar = Calendar.current

        // Bucket by day (start of day)
        var dayMaxes: [Date: Double] = [:]
        for s in samples {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: s.at))
            dayMaxes[day] = max(dayMaxes[day, default: 0], s.max)
        }

        guard let best = dayMaxes.max(by: { $0.value < $1.value }) else { return nil }
        return PeakDayRecord(
            date: best.key,
            costUSD: 0,
            utilizationPercent: best.value,
            isHistoricalPeak: true
        )
    }

    public static func aggregate(
        timeframe: AnalyticsTimeframe,
        compareWithPrevious: Bool,
        now: Date = Date(),
        histories: [VendorId: [UsageHistoryStore.Sample]] = [:],
        estimates: [VendorId: CostEstimate] = [:],
        snapshots: [VendorId: VendorSnapshot] = [:]
    ) -> GlobalAnalyticsSnapshot {
        var vendorSummaries: [VendorAnalyticsSummary] = []
        var totalCostUSD: Double = 0

        // Gather all participating vendors
        let allVendors = Set(estimates.keys).union(snapshots.keys).union(histories.keys)
            .sorted { $0.rawValue < $1.rawValue }

        for vendor in allVendors {
            let estimate = estimates[vendor]
            let snapshot = snapshots[vendor]
            let history = histories[vendor] ?? []

            // Determine cost and breakdown for timeframe
            let cost: Double
            let modelBreakdown: [String: Double]
            switch timeframe {
            case .daily:
                cost = estimate?.usdToday ?? 0
                modelBreakdown = estimate?.modelBreakdownToday ?? [:]
            case .weekly, .monthly:
                cost = estimate?.usdLast7Days ?? estimate?.usdToday ?? 0
                modelBreakdown = estimate?.modelBreakdownLast7Days ?? estimate?.modelBreakdownToday ?? [:]
            }

            totalCostUSD += cost

            // Peak day from history
            let peakDay = computePeakDay(from: history, now: now)

            // Calculate usage percentage from snapshot or history
            let historyMax = history.map { $0.max }.max() ?? 0
            let usagePct = snapshot?.maxUtilization ?? historyMax

            // Approximate session count from model totals or snapshot
            var sessionCount = 0
            if let totals = estimate?.totalsByModel {
                for usage in totals.values where usage.inputTokens > 0 {
                    sessionCount += 1
                }
            }

            let summary = VendorAnalyticsSummary(
                vendor: vendor,
                planLabel: snapshot?.planLabel,
                totalCostUSD: cost,
                totalUsagePercent: usagePct,
                sessionCount: sessionCount,
                peakDay: peakDay,
                costByModel: modelBreakdown,
                usageHistory: history,
                deltaPreviousPeriodPercent: nil
            )
            vendorSummaries.append(summary)
        }

        // Compute shares
        var vendorShares: [VendorShare] = []
        for s in vendorSummaries {
            let pct = totalCostUSD > 0 ? (s.totalCostUSD / totalCostUSD) * 100.0 : 0
            let colorIndex = vendorColorIndices[s.vendor] ?? (vendorShares.count % 8)
            vendorShares.append(VendorShare(
                vendor: s.vendor,
                percentage: pct,
                costUSD: s.totalCostUSD,
                colorIndex: colorIndex
            ))
        }

        return GlobalAnalyticsSnapshot(
            timeframe: timeframe,
            compareWithPrevious: compareWithPrevious,
            totalCostUSD: totalCostUSD,
            vendorShares: vendorShares,
            vendorSummaries: vendorSummaries,
            computedAt: now
        )
    }
}
