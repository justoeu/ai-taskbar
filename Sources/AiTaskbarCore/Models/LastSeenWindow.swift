import Foundation

/// The last live reading of a cumulative quota window (a weekly cap).
///
/// Muse's mint response omits `subs_usage` entirely while the 5-hour session
/// window is idle, and the weekly window goes with it — exactly when a spent
/// weekly cap keeps the session idle. Showing nothing there read as "quota
/// left". A weekly window only grows until it resets, so its last reading is
/// a lower bound until `resetsAt`, and it is shown as that, with its time.
public struct LastSeenWindow: Sendable, Equatable, Codable {
    public let window: UsageWindow
    public let observedAt: Date
    /// What the reading belongs to (Muse: the plan name). "Weekly only
    /// grows" holds within one plan of one login; a plan change resets the
    /// cap, so a reading taken under another scope never carries.
    public let scope: String?

    public init(window: UsageWindow, observedAt: Date, scope: String? = nil) {
        self.window = window
        self.observedAt = observedAt
        self.scope = scope
    }

    /// Still a valid lower bound at `now` for `scope`: same scope, and only
    /// before its own reset. A window with no reset date never carries —
    /// nothing says when it ends.
    public func isCarriable(at now: Date, scope: String?) -> Bool {
        guard let resetsAt = window.resetsAt, self.scope == scope else { return false }
        return resetsAt > now && observedAt <= now
    }
}

/// Persists a vendor's `LastSeenWindow` in
/// `~/Library/Application Support/ai-taskbar/quota/<vendor>.json`.
///
/// Not a secret (a percentage and a reset date). Cache, lock and I/O live in
/// `VendorJSONStore` (best-effort: a lost file costs the carried bar until
/// the next live reading, never a wrong number); this type keeps only the
/// carry rules — scope, reset, and how often an unchanged reading re-stamps.
public final class LastSeenWindowStore: Sendable {
    private let store: VendorJSONStore<LastSeenWindow>

    /// An unchanged reading is re-saved at most this often, so the stored
    /// time stays close to the last confirmation without a write per refresh.
    static let refreshInterval: TimeInterval = 15 * 60

    public var vendor: VendorId { store.vendor }
    public var baseDir: URL { store.baseDir }
    public var fileURL: URL { store.fileURL }

    public init(vendor: VendorId, baseDir: URL) {
        self.store = VendorJSONStore(vendor: vendor, baseDir: baseDir)
    }

    public static func defaultFor(_ vendor: VendorId) throws -> LastSeenWindowStore {
        LastSeenWindowStore(vendor: vendor, baseDir: try Paths.supportSubdirectory("quota"))
    }

    /// Records a LIVE reading. Never call it with a cached or carried window:
    /// the stored time would then claim a confirmation that never happened.
    public func record(_ window: UsageWindow, scope: String? = nil, at now: Date = .init()) {
        store.update { stored in
            if let stored, stored.window == window, stored.scope == scope,
               now.timeIntervalSince(stored.observedAt) >= 0,
               now.timeIntervalSince(stored.observedAt) < Self.refreshInterval {
                return (write: nil, result: ())
            }
            return (write: LastSeenWindow(window: window, observedAt: now, scope: scope), result: ())
        }
    }

    /// The stored reading when it is still carriable at `now` for `scope`.
    public func carried(at now: Date = .init(), scope: String? = nil) -> LastSeenWindow? {
        guard let stored = load(), stored.isCarriable(at: now, scope: scope) else { return nil }
        return stored
    }

    /// Forgets the reading (memory and disk), e.g. once the login is gone:
    /// the next login may be another account with its own week.
    public func clear() {
        store.clear()
    }

    public func load() -> LastSeenWindow? {
        store.load()
    }
}
