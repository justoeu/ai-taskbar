import Foundation
import UserNotifications
import AiTaskbarCore

/// Emits macOS notifications when a usage window crosses one of the configured
/// thresholds for the first time within that window. Dedupes per
/// vendor:windowLabel so re-fetches don't re-notify.
@MainActor
public final class NotificationService {
    public let config: NotificationsConfig

    /// Tracks the highest threshold already notified for each vendor:window
    /// since it last dropped below all thresholds.
    private var highestNotified: [String: Double] = [:]

    public init(config: NotificationsConfig) {
        self.config = config
    }

    public func requestAuthorizationIfNeeded() {
        guard config.enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    public func observe(vendor: VendorId, snapshot: VendorSnapshot) {
        guard config.enabled else { return }
        let sortedThresholds = config.notifyAt.sorted()
        guard let minThreshold = sortedThresholds.first else { return }

        for window in snapshot.windows {
            let key = "\(vendor.rawValue):\(window.label)"
            let percent = window.utilizationPercent

            // Window dropped below all thresholds → reset so a new cycle re-arms.
            if percent < minThreshold {
                highestNotified.removeValue(forKey: key)
                continue
            }

            // Find the highest threshold this reading has reached.
            let reached = sortedThresholds.last(where: { percent >= $0 })
            guard let reached else { continue }
            let alreadyNotified = highestNotified[key] ?? -1
            if reached > alreadyNotified {
                highestNotified[key] = reached
                send(vendor: vendor, window: window, threshold: reached)
            }
        }
    }

    private func send(vendor: VendorId, window: UsageWindow, threshold: Double) {
        let content = UNMutableNotificationContent()
        if config.discreet {
            content.title = L10n.localizedString("notif_discreet_title")
            content.body  = L10n.localizedString("notif_discreet_body_fmt", Int(threshold))
        } else {
            content.title = "\(vendor.displayName) — \(window.label) at \(Int(window.utilizationPercent))%"
            content.body  = thresholdMessage(threshold: threshold, window: window)
        }
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "ai-taskbar.\(vendor.rawValue).\(window.label).\(Int(threshold))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    private static var relativeFormatter: RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = L10n.effectiveLocale
        return f
    }

    private func thresholdMessage(threshold: Double, window: UsageWindow) -> String {
        let level: String
        if threshold >= 100 {
            level = L10n.localizedString("notif_limit_reached")
        } else if threshold >= 90 {
            level = L10n.localizedString("notif_approaching_limit")
        } else {
            level = L10n.localizedString("notif_heavy_usage")
        }
        if let resets = window.resetsAt {
            let relative = Self.relativeFormatter.localizedString(for: resets, relativeTo: .now)
            return L10n.localizedString("notif_resets_fmt", level, relative)
        }
        return level
    }
}
