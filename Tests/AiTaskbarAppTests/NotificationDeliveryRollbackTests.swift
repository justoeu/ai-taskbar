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

    func requestAuthorizationIfNeeded() {}

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
    private static let snapshot = VendorSnapshot.anthropic(
        .init(session: UsageWindow(label: "5h", utilizationPercent: 92), weekly: nil))

    private static func service(_ center: FakeNotificationCenter) -> NotificationService {
        NotificationService(config: NotificationsConfig(enabled: true, notifyAt: [90, 100]),
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
}
