import Foundation
import os.lock

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
/// Not a secret (a percentage and a reset date), so no `0o600` of its own;
/// the enclosing directory is `0700`. Best-effort like `CreditBaselineStore`:
/// a lost file costs the carried bar until the next live reading, never a
/// wrong number, so I/O errors must not fail the usage fetch.
public final class LastSeenWindowStore: Sendable {
    public let vendor: VendorId
    public let baseDir: URL
    /// `.loaded(nil)` remembers "nothing stored" too, so a vendor that never
    /// had a reading does not retry the disk on every read.
    private enum LoadState: Sendable { case unloaded, loaded(LastSeenWindow?) }
    private let cached = OSAllocatedUnfairLock(initialState: LoadState.unloaded)
    /// Serializes the read-compare-write in `record` (held across file I/O).
    private let writeGate = NSLock()

    /// An unchanged reading is re-saved at most this often, so the stored
    /// time stays close to the last confirmation without a write per refresh.
    static let refreshInterval: TimeInterval = 15 * 60

    public init(vendor: VendorId, baseDir: URL) {
        self.vendor = vendor
        self.baseDir = baseDir
    }

    public static func defaultFor(_ vendor: VendorId) throws -> LastSeenWindowStore {
        let dir = try Paths.applicationSupport()
            .appendingPathComponent("quota", isDirectory: true)
        try Paths.ensureDir(dir)
        return LastSeenWindowStore(vendor: vendor, baseDir: dir)
    }

    public var fileURL: URL {
        baseDir.appendingPathComponent("\(vendor.rawValue).json")
    }

    /// Records a LIVE reading. Never call it with a cached or carried window:
    /// the stored time would then claim a confirmation that never happened.
    public func record(_ window: UsageWindow, scope: String? = nil, at now: Date = .init()) {
        writeGate.lock()
        defer { writeGate.unlock() }
        if let stored = load(), stored.window == window, stored.scope == scope,
           now.timeIntervalSince(stored.observedAt) >= 0,
           now.timeIntervalSince(stored.observedAt) < Self.refreshInterval {
            return
        }
        save(LastSeenWindow(window: window, observedAt: now, scope: scope))
    }

    /// The stored reading when it is still carriable at `now` for `scope`.
    public func carried(at now: Date = .init(), scope: String? = nil) -> LastSeenWindow? {
        guard let stored = load(), stored.isCarriable(at: now, scope: scope) else { return nil }
        return stored
    }

    /// Forgets the reading (memory and disk), e.g. once the login is gone:
    /// the next login may be another account with its own week.
    public func clear() {
        writeGate.lock()
        defer { writeGate.unlock() }
        cached.withLock { $0 = .loaded(nil) }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Nothing stored: already clear.
        } catch {
            AppLog.lifecycle.warning(
                "\(self.vendor.rawValue, privacy: .public): could not remove the last weekly reading: \(String(describing: error), privacy: .public)")
        }
    }

    public func load() -> LastSeenWindow? {
        if case .loaded(let hit) = cached.withLock({ $0 }) { return hit }
        // Missing or unreadable reads as "nothing stored" (best-effort, like
        // `CreditBaselineStore`): it costs the carried bar, never a number.
        let decoded = (try? Data(contentsOf: fileURL))
            .flatMap { try? SharedCoders.decoder.decode(LastSeenWindow.self, from: $0) }
        cached.withLock { $0 = .loaded(decoded) }
        return decoded
    }

    private func save(_ value: LastSeenWindow) {
        cached.withLock { $0 = .loaded(value) }
        guard let data = try? SharedCoders.encoder.encode(value) else { return }
        do {
            try AtomicFileWrite.write(data, to: fileURL)
        } catch {
            AppLog.lifecycle.warning(
                "\(self.vendor.rawValue, privacy: .public): could not persist the last weekly reading: \(String(describing: error), privacy: .public)")
        }
    }
}
