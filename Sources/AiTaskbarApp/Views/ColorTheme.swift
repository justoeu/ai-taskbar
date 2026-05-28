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
}
