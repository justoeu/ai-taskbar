import Foundation
import SwiftUI
import Charts
import AiTaskbarCore

/// A weekly stacked bar chart showing daily consumption partitioned by model.
/// Each bar represents one calendar day (7 days in the cost window), and the
/// stacking slices represent the models used, with their relative sizes
/// proportional to their token consumption.
public struct WeeklyModelStackedChartView: View {
    public let dailyUsage: [DailyModelUsage]
    public let vendorColor: Color

    private let distinctModels: [String]
    private let points: [ChartPoint]
    private let modelColors: [String: Color]
    private let xDomain: ClosedRange<Date>?

    @State private var hoveredDate: Date? = nil
    @State private var hoveredModel: String? = nil

    private static let palette: [Color] = [
        Color.accentColor,
        Color(red: 0.2, green: 0.75, blue: 0.8),  // Cyan
        Color(red: 0.8, green: 0.4, blue: 0.9),   // Purple
        Color(red: 0.95, green: 0.6, blue: 0.2),  // Orange
        Color(red: 0.3, green: 0.8, blue: 0.5),   // Mint
        Color(red: 0.9, green: 0.35, blue: 0.5),  // Pink
        Color(red: 0.4, green: 0.5, blue: 0.95),  // Indigo
        Color(red: 0.85, green: 0.75, blue: 0.2)  // Amber
    ]

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    public init(dailyUsage: [DailyModelUsage], vendorColor: Color) {
        self.dailyUsage = dailyUsage
        self.vendorColor = vendorColor

        var set = Set<String>()
        var list: [String] = []
        for day in dailyUsage {
            for model in day.usageByModel.keys.sorted() {
                if !set.contains(model) && (day.usageByModel[model]?.totalTokens ?? 0) > 0 {
                    set.insert(model)
                    list.append(model)
                }
            }
        }
        self.distinctModels = list

        var colors: [String: Color] = [:]
        for (idx, m) in list.enumerated() {
            colors[m] = Self.palette[idx % Self.palette.count]
        }
        self.modelColors = colors

        var pts: [ChartPoint] = []
        for day in dailyUsage {
            let dayTotal = day.totalTokens
            for model in day.usageByModel.keys.sorted() {
                guard let usage = day.usageByModel[model] else { continue }
                let tokens = usage.totalTokens
                guard tokens > 0 else { continue }
                let cost = day.costByModel[model] ?? 0
                pts.append(ChartPoint(
                    id: "\(day.date.timeIntervalSince1970)_\(model)",
                    date: day.date,
                    model: model,
                    tokens: tokens,
                    costUSD: cost,
                    dayTotalTokens: dayTotal
                ))
            }
        }
        self.points = pts

        if let first = dailyUsage.first?.date, let last = dailyUsage.last?.date, first <= last {
            let endOfLast = Calendar.current.date(byAdding: .day, value: 1, to: last)
                ?? last.addingTimeInterval(86_400)
            self.xDomain = first...endOfLast
        } else {
            self.xDomain = nil
        }
    }

    private func color(for model: String) -> Color {
        modelColors[model] ?? vendorColor
    }

    private struct ChartPoint: Identifiable {
        let id: String
        let date: Date
        let model: String
        let tokens: Int
        let costUSD: Double
        let dayTotalTokens: Int

        var percentage: Double {
            guard dayTotalTokens > 0 else { return 0 }
            return (Double(tokens) / Double(dayTotalTokens)) * 100.0
        }
    }

    private var totalWeeklyTokens: Int {
        dailyUsage.reduce(0) { CostAggregator.saturatingAdd($0, $1.totalTokens) }
    }

    private var totalWeeklyCost: Double {
        dailyUsage.reduce(0) { $0 + $1.totalCostUSD }
    }

    private var selectedDay: DailyModelUsage? {
        guard let hoveredDate else { return nil }
        let calendar = Calendar.current
        return dailyUsage.first { calendar.isDate($0.date, inSameDayAs: hoveredDate) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerSection
            chartSection
            if !distinctModels.isEmpty {
                legendSection
            }
        }
        .padding(.top, 2)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(L10n.localizedString("analytics_weekly_models_title"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let day = selectedDay {
                    Text(Self.dayFormatter.string(from: day.date))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                } else {
                    Text(L10n.localizedString("analytics_hover_hint"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let day = selectedDay {
                HStack(spacing: 8) {
                    if let hm = hoveredModel, let u = day.usageByModel[hm] {
                        let tokens = u.totalTokens
                        let pct = day.totalTokens > 0 ? (Double(tokens) / Double(day.totalTokens)) * 100.0 : 0
                        HStack(spacing: 4) {
                            Circle()
                                .fill(color(for: hm))
                                .frame(width: 7, height: 7)
                            Text(hm)
                                .font(.caption.weight(.medium))
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text("\(Self.formatTokens(tokens)) (\(String(format: "%.1f%%", pct)))")
                                .font(.caption.monospacedDigit().weight(.semibold))
                            if let cost = day.costByModel[hm], cost > 0 {
                                Text("•")
                                    .foregroundStyle(.secondary)
                                Text(AnalyticsMoneyFormatter.format(cost))
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("\(Self.formatTokens(day.totalTokens)) \(L10n.localizedString("analytics_tokens"))")
                            .font(.caption.monospacedDigit().weight(.semibold))
                        if day.totalCostUSD > 0 {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(AnalyticsMoneyFormatter.format(day.totalCostUSD))
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        let activeModelCount = day.usageByModel.filter { $0.value.totalTokens > 0 }.count
                        Text(String(format: L10n.localizedString("analytics_models_count"), activeModelCount))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
            } else {
                HStack(spacing: 6) {
                    Text("\(Self.formatTokens(totalWeeklyTokens)) \(L10n.localizedString("analytics_tokens"))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                    if totalWeeklyCost > 0 {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(AnalyticsMoneyFormatter.format(totalWeeklyCost))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var chartSection: some View {
        let calendar = Calendar.current
        return Chart {
            ForEach(points) { p in
                BarMark(
                    x: .value("Day", p.date, unit: .day),
                    y: .value("Tokens", p.tokens)
                )
                .foregroundStyle(color(for: p.model))
                .opacity(barOpacity(for: p))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let n = value.as(Int.self) {
                        Text(Self.formatTokens(n))
                    }
                }
            }
        }
        .frame(height: 105)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if let rawDate: Date = proxy.value(atX: location.x) {
                                let match = dailyUsage.first { calendar.isDate($0.date, inSameDayAs: rawDate) }
                                let newDate = match?.date
                                if hoveredDate != newDate {
                                    withAnimation(.easeInOut(duration: 0.12)) {
                                        hoveredDate = newDate
                                    }
                                }
                            } else {
                                if hoveredDate != nil {
                                    withAnimation(.easeInOut(duration: 0.12)) {
                                        hoveredDate = nil
                                    }
                                }
                            }
                        case .ended:
                            withAnimation(.easeInOut(duration: 0.15)) {
                                hoveredDate = nil
                                hoveredModel = nil
                            }
                        }
                    }
            }
        }
    }

    private func barOpacity(for point: ChartPoint) -> Double {
        let matchesDay = hoveredDate.map { Calendar.current.isDate(point.date, inSameDayAs: $0) } ?? true
        let matchesModel = hoveredModel == nil || point.model == hoveredModel

        if hoveredDate != nil && hoveredModel != nil {
            return (matchesDay && matchesModel) ? 1.0 : 0.25
        } else if hoveredDate != nil {
            return matchesDay ? 1.0 : 0.35
        } else if hoveredModel != nil {
            return matchesModel ? 1.0 : 0.25
        }
        return 0.9
    }

    private var legendSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(distinctModels, id: \.self) { model in
                    let isHovered = hoveredModel == model
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color(for: model))
                            .frame(width: 8, height: 8)
                        Text(model)
                            .font(.caption2.weight(isHovered ? .bold : .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHovered ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08))
                    )
                    .contentShape(Rectangle())
                    .onHover { h in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            if h {
                                hoveredModel = model
                            } else if hoveredModel == model {
                                hoveredModel = nil
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Formats a token count into a human-readable abbreviation (e.g. 1.2K, 3.4M, 1.5B).
    internal static func formatTokens(_ count: Int) -> String {
        let n = Double(count)
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", n / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", n / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", n / 1_000)
        }
        return "\(count)"
    }
}
