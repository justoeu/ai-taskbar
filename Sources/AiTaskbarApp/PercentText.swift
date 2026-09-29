import Foundation
import AiTaskbarCore

/// The one rounding rule for a whole-percent label (CQ-MAE-018). Cards,
/// tooltip, menu bar, pinned badges and the notification title all show
/// `92.9` as `93%`; the notification title used to truncate it to `92%`.
enum PercentText {
    /// Nearest whole percent (half away from zero), saturating so a
    /// non-finite value never traps.
    static func whole(_ percent: Double) -> Int {
        Int(saturating: percent.rounded())
    }

    /// `whole(percent)` followed by a percent sign, e.g. `93%`.
    static func format(_ percent: Double) -> String {
        "\(whole(percent))%"
    }
}
