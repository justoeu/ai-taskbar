import Foundation
import Testing
import UserNotifications
import AiTaskbarCore
@testable import AiTaskbarApp

/// Records every request and holds its completion, so a test decides whether
/// the OS "delivered" it. Never touches the real `UNUserNotificationCenter`.
@MainActor
private final class FakeNotificationCenter: NotificationPosting {
    private(set) var identifiers: [String] = []
    private var completions: [@Sendable (Error?) -> Void] = []
    /// What the OS reports for this app's notification permission.
    var status: UNAuthorizationStatus = .notDetermined
    private(set) var statusQueries = 0

    func requestAuthorizationIfNeeded() {}

    func authorizationStatus(_ completion: @escaping @MainActor @Sendable (UNAuthorizationStatus) -> Void) {
        statusQueries += 1
        completion(status)
    }

    func add(_ request: UNNotificationRequest,
             completion: @escaping @Sendable (Error?) -> Void) {
        identifiers.append(request.identifier)
        completions.append(completion)
    }

    /// Invokes the stored completion off the main thread, as the real center does.
    func complete(_ index: Int, with error: Error?) async {
        let completion = completions[index]
        await Task.detached { completion(error) }.value
    }
}

/// CQ-MAE-012: the crossing was marked in the tracker before `add()` and the
/// completion only logged. On the first crossing authorization is requested
/// asynchronously, so `add()` can fail with `notificationsNotAllowed` and the
/// user never got that notification in the current window.
@MainActor
@Suite("Notification delivery rollback", .serialized)
struct NotificationDeliveryRollbackTests {
    private static let snapshot = anthropic(92)

    private static func anthropic(_ percent: Double) -> VendorSnapshot {
        .anthropic(.init(session: UsageWindow(label: "5h", utilizationPercent: percent), weekly: nil))
    }

    private static func service(_ center: FakeNotificationCenter,
                                notifyAt: [Double] = [90, 100]) -> NotificationService {
        NotificationService(config: NotificationsConfig(enabled: true, notifyAt: notifyAt),
                            center: center, runtimeIncompatible: false)
    }

    @Test("a failed add() re-arms the crossing so the next check re-sends it")
    func failed_add_is_resent() async {
        let center = FakeNotificationCenter()
        let service = Self.service(center)
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        await center.complete(0, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        #expect(center.identifiers.count == 2)
    }

    @Test("a delivered notification is still deduped")
    func delivered_add_is_not_resent() async {
        let center = FakeNotificationCenter()
        let service = Self.service(center)
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        await center.complete(0, with: nil)
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        #expect(center.identifiers.count == 1)
    }

    /// BUG-MAE-011: 70 delivered, 90 failed. The unmark dropped the key, so
    /// the next reading of 75 re-sent the 70 already shown.
    @Test("a failed higher crossing restores the delivered lower mark")
    func failed_higher_crossing_keeps_delivered_lower_mark() async {
        let center = FakeNotificationCenter()
        let service = Self.service(center, notifyAt: [70, 90])
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(75))
        await center.complete(0, with: nil)
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(95))
        await center.complete(1, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(75))
        #expect(center.identifiers.count == 2)
    }

    @Test("after restoring the lower mark the failed higher crossing is still retried")
    func failed_higher_crossing_is_retried() async {
        let center = FakeNotificationCenter()
        let service = Self.service(center, notifyAt: [70, 90])
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(75))
        await center.complete(0, with: nil)
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(95))
        await center.complete(1, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(95))
        #expect(center.identifiers == ["ai-taskbar.anthropic.5h.70",
                                       "ai-taskbar.anthropic.5h.90",
                                       "ai-taskbar.anthropic.5h.90"])
    }

    /// PERF-MAE-004: with permission denied every tick re-armed the crossing,
    /// so each refresh made one more failed add() and one error log line.
    @Test("a failure while authorization is denied does not re-arm the crossing")
    func denied_authorization_does_not_rearm() async {
        let center = FakeNotificationCenter()
        center.status = .denied
        let service = Self.service(center)
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        await center.complete(0, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        #expect(center.identifiers.count == 1)
    }

    @Test("a transient failure with authorization granted still re-arms")
    func authorized_transient_failure_rearms() async {
        let center = FakeNotificationCenter()
        center.status = .authorized
        let service = Self.service(center)
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        await center.complete(0, with: NSError(domain: "test", code: 1))
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        #expect(center.identifiers.count == 2)
    }

    @Test("a known denial is cached: a second failure does not ask the OS again")
    func denial_is_cached() async {
        let center = FakeNotificationCenter()
        center.status = .denied
        let service = Self.service(center)
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        await center.complete(0, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        service.observe(vendor: .xai, snapshot: Self.snapshot)
        await center.complete(1, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        #expect(center.statusQueries == 1)
    }

    @Test("a delivery after a cached denial clears it, so a later failure asks the OS again")
    func delivery_clears_cached_denial() async {
        let center = FakeNotificationCenter()
        center.status = .denied
        let service = Self.service(center)
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        await center.complete(0, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        center.status = .authorized
        service.observe(vendor: .xai, snapshot: Self.snapshot)
        await center.complete(1, with: nil)
        await drainMainQueue()
        service.observe(vendor: .zai, snapshot: Self.snapshot)
        await center.complete(2, with: NSError(domain: "test", code: 1))
        await drainMainQueue()
        #expect(center.statusQueries == 2)
    }

    /// RACE-MAE-003: 70 and 90 both in flight, both fail, 70 first. The 70
    /// failure found 90 recorded and did nothing; the 90 failure then put
    /// back 70, a mark that was never delivered, so 75 no longer re-sent it.
    @Test("a double failure does not restore a lower mark that was never delivered")
    func double_failure_does_not_restore_undelivered_mark() async {
        let center = FakeNotificationCenter()
        let service = Self.service(center, notifyAt: [70, 90])
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(75))
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(95))
        await center.complete(0, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        await center.complete(1, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(75))
        #expect(center.identifiers.last == "ai-taskbar.anthropic.5h.70")
    }

    @Test("a higher failure while the lower crossing is in flight keeps the lower once delivered")
    func higher_failure_keeps_lower_in_flight_mark() async {
        let center = FakeNotificationCenter()
        let service = Self.service(center, notifyAt: [70, 90])
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(75))
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(95))
        await center.complete(1, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        await center.complete(0, with: nil)
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(75))
        #expect(center.identifiers.count == 2)
    }

    /// BUG-MAE-013: the denial was cached and cleared only by a later
    /// delivery, so the crossing that failed while denied stayed marked after
    /// the user granted permission and was never re-sent in that window.
    @Test("a crossing that failed while denied is re-sent once permission is granted")
    func denied_crossing_is_resent_after_grant() async {
        let center = FakeNotificationCenter()
        center.status = .denied
        let service = Self.service(center)
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        await center.complete(0, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        center.status = .authorized
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        #expect(center.identifiers.count == 2)
    }

    @Test("a delivery elsewhere after a denial re-arms the crossing parked by it")
    func delivery_rearms_parked_crossing() async {
        let center = FakeNotificationCenter()
        center.status = .denied
        let service = Self.service(center)
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        await center.complete(0, with: UNError(.notificationsNotAllowed))
        await drainMainQueue()
        service.observe(vendor: .xai, snapshot: Self.snapshot)
        await center.complete(1, with: nil)
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        #expect(center.identifiers.last == "ai-taskbar.anthropic.5h.90")
    }

    /// RACE-MAE-004: pending crossings were keyed by threshold only. After a
    /// reset and a re-cross of the same threshold, the first add()'s late
    /// failure un-marked the new crossing, so it was sent a third time.
    @Test("a stale failure from before a reset does not re-arm the re-crossed threshold")
    func stale_failure_after_reset_is_ignored() async {
        let center = FakeNotificationCenter()
        center.status = .authorized
        let service = Self.service(center)
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(50))
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        await center.complete(0, with: NSError(domain: "test", code: 1))
        await drainMainQueue()
        await center.complete(1, with: nil)
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        #expect(center.identifiers.count == 2)
    }

    /// RACE-MAE-004, other order: the first add()'s late success confirmed
    /// the new crossing, so the new crossing's failure found nothing pending
    /// and the notification was lost for the window.
    @Test("a stale success from before a reset does not confirm the re-crossed threshold")
    func stale_success_after_reset_is_ignored() async {
        let center = FakeNotificationCenter()
        center.status = .authorized
        let service = Self.service(center)
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        service.observe(vendor: .anthropic, snapshot: Self.anthropic(50))
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        await center.complete(0, with: nil)
        await drainMainQueue()
        await center.complete(1, with: NSError(domain: "test", code: 1))
        await drainMainQueue()
        service.observe(vendor: .anthropic, snapshot: Self.snapshot)
        #expect(center.identifiers.count == 3)
    }
}
