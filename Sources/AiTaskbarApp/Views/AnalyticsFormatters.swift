import Foundation
import SwiftUI
import AiTaskbarCore

public enum AnalyticsMoneyFormatter {
    private static let standardFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencySymbol = "$"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    public static func format(_ value: Double) -> String {
        if value > 0 && value < 0.01 {
            return "< $0.01"
        }
        return standardFormatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    public static func formatCompact(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "$%.1fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "$%.1fK", value / 1_000)
        } else {
            return format(value)
        }
    }
}

@MainActor
public enum AnalyticsFormatters {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    public static func peakDayText(_ record: PeakDayRecord) -> String {
        let dateStr = dateFormatter.string(from: record.date)
        if record.costUSD > 0 {
            return "🔥 \(L10n.localizedString("analytics_busiest_day")): \(dateStr) (\(AnalyticsMoneyFormatter.format(record.costUSD)) / \(quotaText(record.utilizationPercent)))"
        } else {
            return "🔥 \(L10n.localizedString("analytics_busiest_day")): \(dateStr) (\(quotaText(record.utilizationPercent)))"
        }
    }

    /// "85% quota", localized: the word was a hard-coded English suffix on
    /// otherwise localized Analytics strings (CQ-MAE-022).
    public static func quotaText(_ percent: Double) -> String {
        L10n.localizedString("analytics_quota_percent_fmt", PercentText.whole(percent))
    }

    /// The Usage donut's centre label: the mean `totalUsagePercent` of
    /// `vendors` (a vendor without a summary counts as 0), rounded like every
    /// other percent label (CQ-MAE-023).
    static func averageUsageText(vendors: [VendorId], summaries: [VendorAnalyticsSummary]) -> String {
        guard !vendors.isEmpty else { return "0%" }
        let total = vendors.map { vendor in
            summaries.first(where: { $0.vendor == vendor })?.totalUsagePercent ?? 0
        }.reduce(0, +)
        return PercentText.format(total / Double(vendors.count))
    }

    public static func vendorColor(for vendor: VendorId) -> Color {
        switch vendor {
        case .anthropic:  return .orange
        case .openai:     return Color(red: 0.06, green: 0.65, blue: 0.45) // Emerald
        case .xai:        return Color(red: 0.55, green: 0.35, blue: 0.85) // Purple
        case .gemini:     return Color(red: 0.20, green: 0.50, blue: 0.95) // Google Blue
        case .zai:        return Color(red: 0.10, green: 0.70, blue: 0.75) // Teal
        case .openrouter: return Color(red: 0.85, green: 0.25, blue: 0.60) // Magenta
        case .kimi:       return Color(red: 0.95, green: 0.65, blue: 0.15) // Amber
        case .deepseek:   return Color(red: 0.40, green: 0.50, blue: 0.60) // Slate
        case .typesafe:   return Color(red: 0.30, green: 0.75, blue: 0.35) // Green
        }
    }
}
