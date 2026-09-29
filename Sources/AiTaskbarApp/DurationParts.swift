import Foundation
import AiTaskbarCore

/// Splits a duration into the integer parts the views print. The seconds come
/// from outside the app: status-feed incident dates (a feed may carry any
/// epoch, `1e300` included) and `refresh_interval_seconds` from the user's
/// TOML. A bare `Int(Double)` traps on NaN, infinity or anything beyond
/// `Int`'s range, so every split goes through `Int(saturating:)`
/// (BUG-MAE-006). Negative durations read as zero.
enum DurationParts {
    /// Whole hours and the leftover minutes, e.g. 3 h 25 min.
    static func hoursMinutes(_ seconds: TimeInterval) -> (hours: Int, minutes: Int) {
        let totalMinutes = max(0, Int(saturating: seconds / 60))
        return (totalMinutes / 60, totalMinutes % 60)
    }

    /// Whole minutes and the leftover seconds, e.g. 4:05.
    static func minutesSeconds(_ seconds: TimeInterval) -> (minutes: Int, seconds: Int) {
        let total = max(0, Int(saturating: seconds))
        return (total / 60, total % 60)
    }
}
