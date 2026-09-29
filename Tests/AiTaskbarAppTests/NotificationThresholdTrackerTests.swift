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
    /// past cycle's key would otherwise live forever. BUG-MAE-007: it is
    /// forgotten after `pruneAfterMissedSnapshots` consecutive absences.
    @Test("a window label that disappears (rolled monthly cycle) is pruned")
    func rolled_cycle_key_is_pruned() {
        var t = NotificationThresholdTracker()
        _ = t.crossings(vendor: .xai,
                        windows: [UsageWindow(label: "Monthly (2026-08)", utilizationPercent: 95)],
                        sortedThresholds: thresholds)
        for _ in 0..<NotificationThresholdTracker.pruneAfterMissedSnapshots {
            _ = t.crossings(vendor: .xai,
                            windows: [UsageWindow(label: "Monthly (2026-09)", utilizationPercent: 80)],
                            sortedThresholds: thresholds)
        }
        #expect(t.highestNotified.keys.map(\.label) == ["Monthly (2026-09)"])
    }

    @Test("a rolled label survives until the prune threshold is reached")
    func rolled_cycle_key_kept_before_threshold() {
        var t = NotificationThresholdTracker()
        _ = t.crossings(vendor: .xai,
                        windows: [UsageWindow(label: "Monthly (2026-08)", utilizationPercent: 95)],
                        sortedThresholds: thresholds)
        for _ in 1..<NotificationThresholdTracker.pruneAfterMissedSnapshots {
            _ = t.crossings(vendor: .xai,
                            windows: [UsageWindow(label: "Monthly (2026-09)", utilizationPercent: 80)],
                            sortedThresholds: thresholds)
        }
        #expect(t.highestNotified.count == 2)
    }

    /// BUG-MAE-007: a window the vendor omits from one snapshot and reports
    /// again at the same level is the same cycle; notifying again is a dup.
    @Test("a window missing from one snapshot does not re-fire when it returns")
    func transient_absence_does_not_refire() {
        var t = NotificationThresholdTracker()
        let weekly = [UsageWindow(label: "Weekly (7d)", utilizationPercent: 92)]
        _ = t.crossings(vendor: .anthropic, windows: weekly, sortedThresholds: thresholds)
        _ = t.crossings(vendor: .anthropic, windows: [], sortedThresholds: thresholds)
        #expect(t.crossings(vendor: .anthropic, windows: weekly, sortedThresholds: thresholds).isEmpty)
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

    /// CQ-MAE-012: a failed delivery un-marks only its own threshold.
    @Test("unmark leaves a higher threshold marked since then")
    func unmark_keeps_higher_mark() {
        var t = NotificationThresholdTracker()
        let at70 = t.crossings(vendor: .xai, windows: [UsageWindow(label: "W", utilizationPercent: 75)],
                               sortedThresholds: thresholds)
        _ = t.crossings(vendor: .xai, windows: [UsageWindow(label: "W", utilizationPercent: 95)],
                        sortedThresholds: thresholds)
        t.unmark(vendor: .xai, label: "W", threshold: 70, token: at70[0].token)
        expectTrue(t.highestNotified[.init(vendor: .xai, label: "W")] == 90)
    }

    /// BUG-MAE-011: unmark puts back the mark the crossing replaced instead
    /// of dropping the key.
    @Test("unmark restores the mark the failed crossing replaced")
    func unmark_restores_previous_mark() {
        var t = NotificationThresholdTracker()
        _ = t.crossings(vendor: .xai, windows: [UsageWindow(label: "W", utilizationPercent: 75)],
                        sortedThresholds: thresholds)
        let at90 = t.crossings(vendor: .xai, windows: [UsageWindow(label: "W", utilizationPercent: 95)],
                               sortedThresholds: thresholds)
        t.unmark(vendor: .xai, label: "W", threshold: 90, token: at90[0].token)
        expectTrue(t.highestNotified[.init(vendor: .xai, label: "W")] == 70)
    }

    @Test("unmark of the current mark re-fires on the next snapshot")
    func unmark_current_mark_refires() {
        var t = NotificationThresholdTracker()
        let w = [UsageWindow(label: "W", utilizationPercent: 95)]
        let fired = t.crossings(vendor: .xai, windows: w, sortedThresholds: thresholds)
        t.unmark(vendor: .xai, label: "W", threshold: 90, token: fired[0].token)
        #expect(t.crossings(vendor: .xai, windows: w, sortedThresholds: thresholds)
            .map(\.threshold) == [90])
    }

    /// RACE-MAE-004: a completion carrying the token of a crossing that a
    /// reset replaced must not un-mark the re-crossed threshold.
    @Test("unmark with a stale token after reset and re-cross is ignored")
    func unmark_stale_token_is_ignored() {
        var t = NotificationThresholdTracker()
        let w = [UsageWindow(label: "W", utilizationPercent: 95)]
        let first = t.crossings(vendor: .xai, windows: w, sortedThresholds: thresholds)
        _ = t.crossings(vendor: .xai, windows: [UsageWindow(label: "W", utilizationPercent: 5)],
                        sortedThresholds: thresholds)
        _ = t.crossings(vendor: .xai, windows: w, sortedThresholds: thresholds)
        t.unmark(vendor: .xai, label: "W", threshold: 90, token: first[0].token)
        expectTrue(t.highestNotified[.init(vendor: .xai, label: "W")] == 90)
    }
}
