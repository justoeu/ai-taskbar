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

        guard !dayMaxes.isEmpty else { return nil }
        let values = Array(dayMaxes.values)
        guard let maxVal = values.max(), maxVal > 0.5 else { return nil }

        // If all days have essentially the same value (variance < 0.1),
        // it is a static flatline rather than an active usage peak.
        if dayMaxes.count > 1, let minVal = values.min(), maxVal - minVal < 0.1 {
            return nil
        }

        guard let best = dayMaxes.max(by: { a, b in
            if a.value != b.value {
                return a.value < b.value
            }
            return a.key < b.key
        }) else { return nil }

        return PeakDayRecord(
            date: best.key,
            costUSD: 0,
            utilizationPercent: best.value,
            isHistoricalPeak: true
        )
    }

    /// DST-safe day arithmetic, as in `CostWindow`.
    private static func addingDays(_ days: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)
            ?? date.addingTimeInterval(Double(days) * 86_400)
    }

    /// Tokens and requests for the timeframe from a snapshot that carries
    /// them — today TypeSafe's console usage only. Month is nil: the console
    /// series covers seven days, and a 7-day figure under a 30-day label
    /// would understate it.
    public static func activity(from snapshot: VendorSnapshot, timeframe: AnalyticsTimeframe,
                                now: Date, calendar: Calendar) -> VendorActivity? {
        guard case .typesafe(let s) = snapshot, let u = s.usage else { return nil }
        func fill(_ points: [TypeSafeUsagePoint], slots: [Date], unit: Calendar.Component) -> [VendorActivity.Point] {
            slots.map { slot in
                let inSlot = points.filter { calendar.isDate($0.start, equalTo: slot, toGranularity: unit) }
                return VendorActivity.Point(
                    start: slot,
                    tokens: inSlot.reduce(0) { $0 &+ $1.inputTokens &+ $1.outputTokens },
                    requests: inSlot.reduce(0) { $0 &+ $1.requests })
            }
        }
        let today = calendar.startOfDay(for: now)
        switch timeframe {
        case .daily:
            let hours = (0..<24).compactMap { calendar.date(byAdding: .hour, value: $0, to: today) }
            return VendorActivity(inputTokens: u.todayInputTokens, outputTokens: u.todayOutputTokens,
                                  requests: u.todayRequests, granularity: .hour,
                                  series: fill(u.hourly, slots: hours, unit: .hour))
        case .weekly:
            let days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            return VendorActivity(inputTokens: u.weekInputTokens, outputTokens: u.weekOutputTokens,
                                  requests: u.weekRequests, granularity: .day,
                                  series: fill(u.daily, slots: days, unit: .day))
        case .monthly:
            return nil
        }
    }

    public static func aggregate(
        timeframe: AnalyticsTimeframe,
        compareWithPrevious: Bool,
        comparisonOffset: Int = 1,
        now: Date = Date(),
        calendar: Calendar = .current,
        histories: [VendorId: [UsageHistoryStore.Sample]] = [:],
        estimates: [VendorId: CostEstimate] = [:],
        snapshots: [VendorId: VendorSnapshot] = [:]
    ) -> GlobalAnalyticsSnapshot {
        var vendorSummaries: [VendorAnalyticsSummary] = []
        var totalCostUSD: Double = 0

        // Current and comparison periods. Day and Week use the same local
        // calendar days as the cost they sit next to (`CostWindow`: today
        // since midnight; today plus the six previous days), so sessions and
        // the delta cover the period the dollar figure covers (BUG-MAE-005).
        // Month has no cost source and stays a rolling 30 days.
        let nowTs = now.timeIntervalSince1970
        let offset = max(1, comparisonOffset)
        let currentStart: TimeInterval
        let compareStart: TimeInterval
        let compareEnd: TimeInterval
        switch timeframe {
        case .daily, .weekly:
            let window = CostWindow(now: now, calendar: calendar)
            let start = timeframe == .daily ? window.startOfToday : window.startOfLast7Days
            let periodDays = timeframe == .daily ? 1 : 7
            let end = Self.addingDays(-(offset - 1) * periodDays, to: start, calendar: calendar)
            currentStart = start.timeIntervalSince1970
            compareEnd = end.timeIntervalSince1970
            compareStart = Self.addingDays(-periodDays, to: end, calendar: calendar).timeIntervalSince1970
        case .monthly:
            let duration: TimeInterval = 30 * 86_400
            currentStart = nowTs - duration
            compareEnd = nowTs - Double(offset) * duration
            compareStart = compareEnd - duration
        }

        // Gather all participating vendors
        let allVendors = Set(estimates.keys).union(snapshots.keys).union(histories.keys)
            .sorted { $0.rawValue < $1.rawValue }

        for vendor in allVendors {
            let estimate = estimates[vendor]
            let snapshot = snapshots[vendor]
            let history = histories[vendor] ?? []

            // Determine cost and breakdown for timeframe. `CostEstimate` has
            // no 30-day figure (the scanners keep today + last 7 days), so
            // Month has no cost rather than the 7-day number under its label.
            let cost: Double
            let modelBreakdown: [String: Double]
            switch timeframe {
            case .daily:
                cost = estimate?.usdToday ?? 0
                modelBreakdown = estimate?.modelBreakdownToday ?? [:]
            case .weekly:
                cost = estimate?.usdLast7Days ?? estimate?.usdToday ?? 0
                modelBreakdown = estimate?.modelBreakdownLast7Days ?? estimate?.modelBreakdownToday ?? [:]
            case .monthly:
                cost = 0
                modelBreakdown = [:]
            }

            totalCostUSD += cost

            // Peak day from history
            let peakDay = computePeakDay(from: history, now: now)

            // Calculate usage percentage from snapshot or history
            let historyMax = history.map { $0.max }.max() ?? 0
            let usagePct = snapshot?.maxUtilization ?? historyMax

            // Sessions only from real session counters; other vendors report
            // a model count instead (it used to be shown as "sessions").
            var sessionCount = 0
            if vendor == .gemini {
                sessionCount = SessionCounters.antigravityCount(since: Date(timeIntervalSince1970: currentStart))
            } else if vendor == .xai {
                sessionCount = SessionCounters.grokCount(since: Date(timeIntervalSince1970: currentStart))
            }

            // Delta computation if compareWithPrevious is requested
            var deltaPercent: Double? = nil
            if compareWithPrevious, !history.isEmpty {
                let currentSamples = history.filter { $0.at >= currentStart && $0.at <= nowTs }
                let compareSamples = history.filter { $0.at >= compareStart && $0.at < compareEnd }
                if !currentSamples.isEmpty, !compareSamples.isEmpty {
                    let currAvg = currentSamples.map(\.max).reduce(0, +) / Double(currentSamples.count)
                    let compAvg = compareSamples.map(\.max).reduce(0, +) / Double(compareSamples.count)
                    deltaPercent = computeDelta(current: currAvg, previous: compAvg)
                }
            }

            let summary = VendorAnalyticsSummary(
                vendor: vendor,
                planLabel: snapshot?.planLabel,
                totalCostUSD: cost,
                totalUsagePercent: usagePct,
                sessionCount: sessionCount,
                modelCount: modelBreakdown.count,
                isCostAvailable: timeframe != .monthly,
                peakDay: peakDay,
                costByModel: modelBreakdown,
                usageHistory: history,
                deltaPreviousPeriodPercent: deltaPercent,
                lifetimeCostUSD: snapshot?.lifetimeCostUSD,
                activity: snapshot.flatMap { activity(from: $0, timeframe: timeframe, now: now, calendar: calendar) }
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
            comparisonOffset: comparisonOffset,
            totalCostUSD: totalCostUSD,
            vendorShares: vendorShares,
            vendorSummaries: vendorSummaries,
            computedAt: now,
            isCostAvailable: timeframe != .monthly
        )
    }
}
