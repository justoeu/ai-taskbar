import SwiftUI
import AiTaskbarCore

public enum SeverityColor {
    /// Backwards-compatible default thresholds (70/90).
    public static func tint(forPercent pct: Double) -> Color {
        tint(forPercent: pct, thresholds: ThresholdsConfig())
    }

    public static func tint(forPercent pct: Double, thresholds: ThresholdsConfig) -> Color {
        if pct >= 100 { return .red }
        if pct >= thresholds.critical { return .orange }
        if pct >= thresholds.warning  { return .yellow }
        return .green
    }

    /// Whether the menu-bar flame is shown next to a percentage.
    public static func showsFlame(forPercent pct: Double, thresholds: ThresholdsConfig) -> Bool {
        pct >= thresholds.warning || pct >= 100
    }

    /// Menu-bar flame tint. Deliberately a two-tier scale distinct from
    /// `tint`: orange from warning, red from critical (not from 100 %). The
    /// flame only appears at >= warning, so its red marks the critical band.
    /// Single source for `MenuBarLabelView` and `PinnedStatusBadgeView`.
    public static func flameTint(forPercent pct: Double, thresholds: ThresholdsConfig) -> Color {
        (pct >= thresholds.critical || pct >= 100) ? .red : .orange
    }
}

extension ServiceStatusLevel {
    var statusColor: Color {
        switch ServiceStatusPresentation.tone(for: self) {
        case .positive: return .green
        case .maintenance: return .purple
        case .warning: return .orange
        case .danger: return .red
        case .secondary: return .secondary
        }
    }
}
