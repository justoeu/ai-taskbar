import Foundation
import UserNotifications
import AiTaskbarCore

/// The two `UNUserNotificationCenter` calls the service makes, behind a seam
/// so tests never reach the real center (which needs a bundled app and, on
/// macOS 26, crashes the SDK-mismatched XPC handshake).
@MainActor
protocol NotificationPosting {
    func requestAuthorizationIfNeeded()
    /// The app's current notification permission, delivered on the main actor.
    func authorizationStatus(_ completion: @escaping @MainActor @Sendable (UNAuthorizationStatus) -> Void)
    func add(_ request: UNNotificationRequest,
             completion: @escaping @Sendable (Error?) -> Void)
}

struct SystemNotificationCenter: NotificationPosting {
    func requestAuthorizationIfNeeded() {
        // Re-fetch `current()` inside the callback instead of capturing it.
        // `UNUserNotificationCenter` is not `Sendable`, and the settings
        // callback is `@Sendable`, so capturing the outer reference was a
        // concurrency hole rather than a style nit. `current()` returns the
        // same process-wide singleton, so this is free.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func authorizationStatus(_ completion: @escaping @MainActor @Sendable (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in completion(status) }
        }
    }

    func add(_ request: UNNotificationRequest,
             completion: @escaping @Sendable (Error?) -> Void) {
        UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
    }
}

/// Emits macOS notifications when a usage window crosses one of the configured
/// thresholds for the first time within that window. Dedupes per
/// vendor:windowLabel so re-fetches don't re-notify.
@MainActor
public final class NotificationService {
    public let config: NotificationsConfig

    /// Tracks the highest threshold already notified for each vendor:window
    /// since it last dropped below all thresholds.
    private var tracker = NotificationThresholdTracker()

    /// Whether the OS authorization prompt has already been requested in
    /// this process. The auth request is deferred until the first notification
    /// actually needs to fire, so apps with notifications disabled (or that
    /// never cross a threshold) never establish the usernotifications XPC
    /// connection at all.
    private var authorizationRequested = false

    /// Set when a failed delivery found the permission denied; cleared by the
    /// next successful delivery, or by a re-check that finds it granted. While
    /// set, a failure parks its crossing (kept marked) instead of re-arming
    /// it, so a denied app does not retry (and log) on every refresh tick
    /// (PERF-MAE-004). Clearing it re-arms the parked crossings (BUG-MAE-013).
    private var authorizationKnownDenied = false

    /// A permission re-check for parked crossings is awaiting the OS.
    private var authorizationRecheckInFlight = false

    private let center: NotificationPosting
    private let runtimeIncompatible: Bool

    public convenience init(config: NotificationsConfig) {
        self.init(config: config, center: SystemNotificationCenter(),
                  runtimeIncompatible: Self.isRuntimeKnownIncompatible)
    }

    /// Test seam: a fake center and an explicit runtime gate, so the send
    /// path is exercisable on macOS 26 without the real center.
    init(config: NotificationsConfig, center: NotificationPosting, runtimeIncompatible: Bool) {
        self.config = config
        self.center = center
        self.runtimeIncompatible = runtimeIncompatible
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
        center.requestAuthorizationIfNeeded()
    }

    public func observe(vendor: VendorId, snapshot: VendorSnapshot) {
        // Skip entirely on runtimes where the usernotifications XPC handshake
        // is known to crash this binary (Tahoe / macOS 26 until the release
        // pipeline rebuilds against the matching SDK). Surfacing the guard
        // here keeps `observe()` cheap in the common path.
        guard config.enabled, !runtimeIncompatible else { return }
        recheckDeniedAuthorization(for: vendor)
        let sortedThresholds = config.notifyAt.sorted()
        for crossing in tracker.crossings(vendor: vendor, windows: snapshot.windows,
                                          sortedThresholds: sortedThresholds) {
            ensureAuthorizedBeforeSend()
            send(vendor: vendor, window: crossing.window, threshold: crossing.threshold)
        }
    }

    /// A crossing parked by a denial stayed marked after the user granted
    /// permission (BUG-MAE-013). Asks the OS again when this vendor has a
    /// parked crossing: one settings query per such vendor per tick, no
    /// `add()` and no log. A grant re-arms them for the next snapshot.
    private func recheckDeniedAuthorization(for vendor: VendorId) {
        guard authorizationKnownDenied, !authorizationRecheckInFlight,
              tracker.hasParked(vendor: vendor) else { return }
        authorizationRecheckInFlight = true
        center.authorizationStatus { [weak self] status in
            guard let self else { return }
            self.authorizationRecheckInFlight = false
            guard status != .denied else { return }
            self.clearKnownDenial()
        }
    }

    private func clearKnownDenial() {
        authorizationKnownDenied = false
        tracker.rearmParked()
    }

    private func send(vendor: VendorId, window: UsageWindow, threshold: Double) {
        // Defense in depth: never reach `UNUserNotificationCenter` on a
        // runtime known to crash the XPC handshake. `observe()` already
        // filters this, but `send()` is private and could be reused later.
        if runtimeIncompatible { return }
        let content = UNMutableNotificationContent()
        if config.discreet {
            content.title = L10n.localizedString("notif_discreet_title")
            content.body  = L10n.localizedString("notif_discreet_body_fmt", Int(saturating: threshold))
        } else {
            content.title = Self.title(vendor: vendor, window: window)
            content.body  = thresholdMessage(threshold: threshold, window: window)
        }
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "ai-taskbar.\(vendor.rawValue).\(window.label).\(Int(saturating: threshold))",
            content: content,
            trigger: nil
        )
        let label = window.label
        center.add(req) { [weak self] error in
            let failure = error.map { String(describing: $0) }
            Task { @MainActor in
                self?.deliveryFinished(failure: failure, vendor: vendor, label: label,
                                       threshold: threshold)
            }
        }
    }

    /// The crossing was marked before `add()`. On failure it is un-marked so
    /// the next refresh re-sends it: on the first crossing authorization is
    /// still pending and `add()` fails with `notificationsNotAllowed`
    /// (CQ-MAE-012). Not when the permission is denied: no retry can succeed
    /// then (PERF-MAE-004), so it is parked until permission comes back.
    private func deliveryFinished(failure: String?, vendor: VendorId, label: String,
                                  threshold: Double) {
        guard let failure else {
            tracker.delivered(vendor: vendor, label: label, threshold: threshold)
            if authorizationKnownDenied { clearKnownDenial() }
            return
        }
        AppLog.lifecycle.error("notification delivery failed: \(failure, privacy: .public)")
        guard !authorizationKnownDenied else {
            tracker.park(vendor: vendor, label: label, threshold: threshold)
            return
        }
        center.authorizationStatus { [weak self] status in
            guard let self else { return }
            if status == .denied {
                self.authorizationKnownDenied = true
                self.tracker.park(vendor: vendor, label: label, threshold: threshold)
                return
            }
            self.tracker.unmark(vendor: vendor, label: label, threshold: threshold)
        }
    }

    /// Non-discreet title, e.g. "Claude — 5h at 92%". Localized: it was a
    /// hard-coded English sentence while the body beside it was not
    /// (CQ-MAE-012). The window label is shown as the card shows it.
    static func title(vendor: VendorId, window: UsageWindow) -> String {
        L10n.localizedString("notif_title_fmt", vendor.displayName, window.label,
                             PercentText.whole(window.utilizationPercent))
    }

    /// Built once. The locale is captured at first use, which is after
    /// `AiTaskbarApp.init` applied the language override; a language change
    /// needs a relaunch anyway (same contract as `PopoverContentView`).
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = L10n.effectiveLocale
        return f
    }()

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

/// Pure dedupe bookkeeping behind `NotificationService.observe`, split out so
/// it is testable on runtimes where the service itself is short-circuited.
struct NotificationThresholdTracker {
    struct Key: Hashable {
        let vendor: VendorId
        let label: String
    }

    /// Highest threshold already notified per vendor window since it last
    /// dropped below every threshold.
    private(set) var highestNotified: [Key: Double] = [:]

    /// Consecutive snapshots of the key's vendor that did not report it.
    private var missedSnapshots: [Key: Int] = [:]

    /// A crossing whose delivery has not been confirmed: the mark it replaced
    /// and whether a denial parked it.
    private struct Pending {
        var previous: Double?
        var parked = false
    }

    /// Unconfirmed crossings per key, by threshold. They chain through
    /// `previous`, so a failure can restore the nearest mark that was not
    /// itself a failure (RACE-MAE-003). Dropped with the key on reset/prune.
    private var pending: [Key: [Double: Pending]] = [:]

    /// A window must be absent this many consecutive snapshots of its vendor
    /// before its key is forgotten. One missing snapshot (a vendor omitting a
    /// window for one poll) no longer re-arms it, so its return does not
    /// repeat a notification already shown (BUG-MAE-007). A rolled label
    /// (xAI "Monthly (YYYY-MM)") never returns, so it is still pruned:
    /// about an hour later at the default 300 s cadence.
    static let pruneAfterMissedSnapshots = 12

    /// Forgets a crossing whose delivery failed, so the next snapshot re-fires
    /// it, by putting back the mark it replaced (nil: none). The key is not
    /// dropped: a lower threshold already delivered would then be re-sent by
    /// the next lower reading (BUG-MAE-011). When a higher threshold was
    /// marked in the meantime it stays; a still-pending higher crossing that
    /// would restore this one restores what this one replaced instead, so a
    /// mark that was never delivered is never put back (RACE-MAE-003). A
    /// reset since the crossing (no pending entry) must not be undone.
    mutating func unmark(vendor: VendorId, label: String, threshold: Double) {
        let key = Key(vendor: vendor, label: label)
        guard let failed = pending[key]?.removeValue(forKey: threshold) else { return }
        if highestNotified[key] == threshold {
            highestNotified[key] = failed.previous
        } else {
            for (higher, entry) in pending[key] ?? [:] where entry.previous == threshold {
                pending[key]?[higher]?.previous = failed.previous
            }
        }
        if pending[key]?.isEmpty ?? false { pending.removeValue(forKey: key) }
    }

    /// The crossing's delivery was confirmed: its mark is final.
    mutating func delivered(vendor: VendorId, label: String, threshold: Double) {
        let key = Key(vendor: vendor, label: label)
        pending[key]?.removeValue(forKey: threshold)
        if pending[key]?.isEmpty ?? false { pending.removeValue(forKey: key) }
    }

    /// Keeps a crossing that failed while permission is denied marked, to be
    /// re-armed by `rearmParked()` once permission is granted (BUG-MAE-013).
    mutating func park(vendor: VendorId, label: String, threshold: Double) {
        pending[Key(vendor: vendor, label: label)]?[threshold]?.parked = true
    }

    func hasParked(vendor: VendorId) -> Bool {
        pending.contains { key, byThreshold in
            key.vendor == vendor && byThreshold.values.contains { $0.parked }
        }
    }

    /// Un-marks every parked crossing so the next snapshot re-sends it.
    mutating func rearmParked() {
        let parked = pending.flatMap { key, byThreshold in
            byThreshold.filter { $0.value.parked }.map { (key, $0.key) }
        }
        for (key, threshold) in parked {
            unmark(vendor: key.vendor, label: key.label, threshold: threshold)
        }
    }

    typealias Crossing = (window: UsageWindow, threshold: Double)

    /// Folds one snapshot's windows in and returns the crossings to notify.
    /// Each stays pending until `delivered` or `unmark`.
    mutating func crossings(vendor: VendorId, windows: [UsageWindow],
                            sortedThresholds: [Double]) -> [Crossing] {
        guard let minThreshold = sortedThresholds.first else { return [] }
        var fired: [Crossing] = []
        for window in windows {
            let key = Key(vendor: vendor, label: window.label)
            let percent = window.utilizationPercent
            // Window dropped below all thresholds → reset so a new cycle re-arms.
            if percent < minThreshold {
                highestNotified.removeValue(forKey: key)
                missedSnapshots.removeValue(forKey: key)
                pending.removeValue(forKey: key)
                continue
            }
            // Find the highest threshold this reading has reached.
            guard let reached = sortedThresholds.last(where: { percent >= $0 }) else { continue }
            let previous = highestNotified[key]
            if reached > previous ?? -1 {
                highestNotified[key] = reached
                pending[key, default: [:]][reached] = Pending(previous: previous)
                fired.append((window, reached))
            }
        }
        // Prune this vendor's keys for windows no longer reported (xAI's
        // "Monthly (YYYY-MM)" label rolls every cycle and would orphan one),
        // but only after `pruneAfterMissedSnapshots` consecutive absences.
        let current = Set(windows.map { Key(vendor: vendor, label: $0.label) })
        for key in current { missedSnapshots.removeValue(forKey: key) }
        for key in highestNotified.keys where key.vendor == vendor && !current.contains(key) {
            let misses = missedSnapshots[key, default: 0] + 1
            if misses >= Self.pruneAfterMissedSnapshots {
                highestNotified.removeValue(forKey: key)
                missedSnapshots.removeValue(forKey: key)
                pending.removeValue(forKey: key)
            } else {
                missedSnapshots[key] = misses
            }
        }
        return fired
    }
}
