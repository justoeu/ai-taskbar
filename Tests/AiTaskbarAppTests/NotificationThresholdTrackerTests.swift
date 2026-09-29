import Testing
import Foundation
@testable import AiTaskbarApp
@testable import AiTaskbarCore

@Suite("NotificationThresholdTracker — per-window dedupe")
struct NotificationThresholdTrackerTests {
    private let thresholds: [Double] = [70, 90]

    @Test("a crossing fires once, then is deduped")
    func fires_once() {
        var t = NotificationThresholdTracker()
        let w = [UsageWindow(label: "Weekly (7d)", utilizationPercent: 75)]
        #expect(t.crossings(vendor: .anthropic, windows: w, sortedThresholds: thresholds)
            .map(\.threshold) == [70])
        #expect(t.crossings(vendor: .anthropic, windows: w, sortedThresholds: thresholds).isEmpty)
    }

    @Test("dropping below every threshold re-arms the window")
    func rearms() {
        var t = NotificationThresholdTracker()
        _ = t.crossings(vendor: .xai, windows: [UsageWindow(label: "W", utilizationPercent: 95)],
                        sortedThresholds: thresholds)
        _ = t.crossings(vendor: .xai, windows: [UsageWindow(label: "W", utilizationPercent: 5)],
                        sortedThresholds: thresholds)
        #expect(t.highestNotified.isEmpty)
    }

    /// LEAK-FAN-007: xAI labels its monthly window "Monthly (YYYY-MM)", so a
    /// past cycle's key would otherwise live forever.
    @Test("a window label that disappears (rolled monthly cycle) is pruned")
    func rolled_cycle_key_is_pruned() {
        var t = NotificationThresholdTracker()
        _ = t.crossings(vendor: .xai,
                        windows: [UsageWindow(label: "Monthly (2026-08)", utilizationPercent: 95)],
                        sortedThresholds: thresholds)
        _ = t.crossings(vendor: .xai,
                        windows: [UsageWindow(label: "Monthly (2026-09)", utilizationPercent: 80)],
                        sortedThresholds: thresholds)
        #expect(t.highestNotified.keys.map(\.label) == ["Monthly (2026-09)"])
    }

    @Test("pruning one vendor leaves other vendors' keys alone")
    func prune_is_per_vendor() {
        var t = NotificationThresholdTracker()
        _ = t.crossings(vendor: .anthropic,
                        windows: [UsageWindow(label: "Weekly (7d)", utilizationPercent: 95)],
                        sortedThresholds: thresholds)
        _ = t.crossings(vendor: .xai,
                        windows: [UsageWindow(label: "Monthly (2026-09)", utilizationPercent: 80)],
                        sortedThresholds: thresholds)
        #expect(t.highestNotified.count == 2)
    }
}
