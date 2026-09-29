import Testing
import SwiftUI
@testable import AiTaskbarApp
@testable import AiTaskbarCore

/// ARCH-ATL-007: the flame rule used by the menu bar and pinned badges lives
/// in one helper. Its critical..99 band is red (current menu-bar behavior),
/// which deliberately differs from `tint` (orange there).
@Suite("SeverityColor flame rule")
struct SeverityColorFlameTests {
    private let t = ThresholdsConfig(warning: 70, critical: 90)

    @Test("no flame below warning")
    func hidden_below_warning() {
        #expect(!SeverityColor.showsFlame(forPercent: 69, thresholds: t))
    }

    @Test("flame shown from warning")
    func shown_from_warning() {
        #expect(SeverityColor.showsFlame(forPercent: 70, thresholds: t))
    }

    @Test("flame shown at 100 even with thresholds above 100")
    func shown_at_100() {
        #expect(SeverityColor.showsFlame(forPercent: 100,
                                         thresholds: ThresholdsConfig(warning: 150, critical: 200)))
    }

    @Test("warning..critical band is orange")
    func warning_band_orange() {
        #expect(SeverityColor.flameTint(forPercent: 80, thresholds: t) == .orange)
    }

    @Test("critical..99 band is red")
    func critical_band_red() {
        #expect(SeverityColor.flameTint(forPercent: 95, thresholds: t) == .red)
    }

    @Test("100 is red even with a critical threshold above 100")
    func full_is_red() {
        #expect(SeverityColor.flameTint(forPercent: 100,
                                        thresholds: ThresholdsConfig(warning: 150, critical: 200)) == .red)
    }
}
