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

    /// Whether the OS authorization prompt has already been requested in
    /// this process. The auth request is deferred until the first notification
    /// actually needs to fire, so apps with notifications disabled (or that
    /// never cross a threshold) never establish the usernotifications XPC
    /// connection at all.
    private var authorizationRequested = false

    public init(config: NotificationsConfig) {
        self.config = config
    }

    /// Returns `true` when the running macOS is known to crash this binary
    /// during the `UNUserNotificationCenter` XPC handshake. Binaries built
    /// against an older SDK (the GitHub Actions runners currently ship
    /// `macos-15` / Xcode 16) hit an `EXC_BREAKPOINT` during the daemon's
    /// JSONDecoder callback on Tahoe (macOS 26), killing the app within ~20 ms
    /// of launch. Until the release pipeline moves to a `macos-26` runner,
    /// we short-circuit notifications entirely on that OS so the rest of the
    /// app keeps working. Surfaced publicly so the Settings UI can explain
    /// *why* the toggle is inert instead of leaving the user guessing.
    public static let isRuntimeKnownIncompatible: Bool = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion >= 26
    }()

    /// Lazily requests OS notification authorization the first time a
    /// notification actually needs to fire. Deferring this until the first
    /// send means apps with notifications disabled (or that never cross a
    /// threshold) never establish the usernotifications XPC connection at
    /// all — which was the boot-time crash vector on macOS 26.
    private func ensureAuthorizedBeforeSend() {
        guard config.enabled, !authorizationRequested else { return }
        authorizationRequested = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    public func observe(vendor: VendorId, snapshot: VendorSnapshot) {
        // Skip entirely on runtimes where the usernotifications XPC handshake
        // is known to crash this binary (Tahoe / macOS 26 until the release
        // pipeline rebuilds against the matching SDK). Surfacing the guard
        // here keeps `observe()` cheap in the common path.
        guard config.enabled, !Self.isRuntimeKnownIncompatible else { return }
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
                ensureAuthorizedBeforeSend()
                send(vendor: vendor, window: window, threshold: reached)
            }
        }
    }

    private func send(vendor: VendorId, window: UsageWindow, threshold: Double) {
        // Defense in depth: never reach `UNUserNotificationCenter` on a
        // runtime known to crash the XPC handshake. `observe()` already
        // filters this, but `send()` is private and could be reused later.
        if Self.isRuntimeKnownIncompatible { return }
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
