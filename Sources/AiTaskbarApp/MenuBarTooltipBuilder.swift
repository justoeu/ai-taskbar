import Foundation
import AiTaskbarCore

@MainActor
public enum MenuBarTooltipBuilder {
    /// Builds the multi-line tooltip for a pinned vendor item in the menu bar.
    ///
    /// If reset windows are available:
    /// ```
    /// Vendor Name
    /// Diário: falta 2 horas e 30 minutos
    /// Semanal: falta 3 dias e 4 horas
    /// ```
    /// If no reset window is available (e.g. prepaid balance without reset):
    /// ```
    /// Vendor Name: 42%
    /// ```
    public static func buildTooltip(
        vendorId: VendorId,
        snapshot: VendorSnapshot?,
        currentPercent: Double,
        now: Date = Date(),
        locale: Locale = L10n.effectiveLocale
    ) -> String {
        guard let snapshot else {
            return "\(vendorId.displayName): \(Int(currentPercent.rounded()))%"
        }

        let (dailyWindow, weeklyWindow) = snapshot.menuBarResetWindows

        var lines: [String] = []

        if let dailyWindow, let resetsAt = dailyWindow.resetsAt {
            if dailyWindow.isAwaitingReset(now: now) {
                lines.append(L10n.localizedString("tooltip_daily_reset_waiting"))
            } else {
                let timeStr = formatCountdown(from: now, to: resetsAt, locale: locale)
                if !timeStr.isEmpty {
                    lines.append(L10n.localizedString("tooltip_daily_reset_fmt", timeStr))
                }
            }
        }

        if let weeklyWindow, let resetsAt = weeklyWindow.resetsAt {
            if weeklyWindow.isAwaitingReset(now: now) {
                lines.append(L10n.localizedString("tooltip_weekly_reset_waiting"))
            } else {
                let timeStr = formatCountdown(from: now, to: resetsAt, locale: locale)
                if !timeStr.isEmpty {
                    lines.append(L10n.localizedString("tooltip_weekly_reset_fmt", timeStr))
                }
            }
        }

        if lines.isEmpty {
            return "\(vendorId.displayName): \(Int(currentPercent.rounded()))%"
        }

        return ([vendorId.displayName] + lines).joined(separator: "\n")
    }

    /// Formats the remaining time delta from `now` to `resetsAt`.
    public static func formatCountdown(
        from now: Date,
        to resetsAt: Date,
        locale: Locale = L10n.effectiveLocale
    ) -> String {
        let delta = resetsAt.timeIntervalSince(now)
        if delta <= 0 {
            return ""
        }
        if delta < 60 {
            return L10n.localizedString("time_less_than_minute")
        }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar

        return formatter.string(from: delta) ?? ""
    }
}
