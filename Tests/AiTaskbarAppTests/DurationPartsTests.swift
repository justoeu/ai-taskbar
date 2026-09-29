import Testing
import Foundation
@testable import AiTaskbarApp

/// BUG-MAE-006: incident durations (status-feed dates) and the refresh
/// countdown (`refresh_interval_seconds` from TOML) are external numbers.
/// A bare `Int(Double)` on them trapped the app on NaN / infinity / 1e300.
@Suite("DurationParts")
struct DurationPartsTests {
    @Test("hours/minutes of an infinite incident span saturate instead of trapping")
    func hours_minutes_infinite() {
        let parts = DurationParts.hoursMinutes(.infinity)
        #expect(parts.hours == Int.max / 60)
    }

    @Test("hours/minutes of a 1e300 s span saturate instead of trapping")
    func hours_minutes_huge() {
        let parts = DurationParts.hoursMinutes(1e300)
        #expect(parts.minutes == Int.max % 60)
    }

    @Test("hours/minutes of NaN read as zero")
    func hours_minutes_nan() {
        let parts = DurationParts.hoursMinutes(.nan)
        #expect(parts.hours == 0)
        #expect(parts.minutes == 0)
    }

    @Test("hours/minutes of a negative span (clock skew) read as zero")
    func hours_minutes_negative() {
        #expect(DurationParts.hoursMinutes(-3_600).hours == 0)
    }

    @Test("hours/minutes split a normal span")
    func hours_minutes_normal() {
        let parts = DurationParts.hoursMinutes(3 * 3_600 + 25 * 60 + 59)
        #expect(parts.hours == 3)
        #expect(parts.minutes == 25)
    }

    @Test("countdown of a 1e300 s refresh interval saturates instead of trapping")
    func minutes_seconds_huge() {
        let parts = DurationParts.minutesSeconds(1e300)
        #expect(parts.minutes == Int.max / 60)
    }

    @Test("countdown splits a normal remainder")
    func minutes_seconds_normal() {
        let parts = DurationParts.minutesSeconds(245.9)
        #expect(parts.minutes == 4)
        #expect(parts.seconds == 5)
    }
}
