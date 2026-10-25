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

    public init(window: UsageWindow, observedAt: Date) {
        self.window = window
        self.observedAt = observedAt
    }

    /// Still a valid lower bound at `now`: only before its own reset. A
    /// window with no reset date never carries — nothing says when it ends.
    public func isCarriable(at now: Date) -> Bool {
        guard let resetsAt = window.resetsAt else { return false }
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
    private let cached = OSAllocatedUnfairLock(initialState: LastSeenWindow?.none)
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
    public func record(_ window: UsageWindow, at now: Date = .init()) {
        writeGate.lock()
        defer { writeGate.unlock() }
        if let stored = load(), stored.window == window,
           now.timeIntervalSince(stored.observedAt) >= 0,
           now.timeIntervalSince(stored.observedAt) < Self.refreshInterval {
            return
        }
        save(LastSeenWindow(window: window, observedAt: now))
    }

    /// The stored reading when it is still carriable at `now`.
    public func carried(at now: Date = .init()) -> LastSeenWindow? {
        guard let stored = load(), stored.isCarriable(at: now) else { return nil }
        return stored
    }

    public func load() -> LastSeenWindow? {
        if let hit = cached.withLock({ $0 }) { return hit }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? SharedCoders.decoder.decode(LastSeenWindow.self, from: data)
        else { return nil }
        cached.withLock { $0 = decoded }
        return decoded
    }

    private func save(_ value: LastSeenWindow) {
        cached.withLock { $0 = value }
        guard let data = try? SharedCoders.encoder.encode(value) else { return }
        do {
            try AtomicFileWrite.write(data, to: fileURL)
        } catch {
            AppLog.lifecycle.warning(
                "\(self.vendor.rawValue, privacy: .public): could not persist the last weekly reading: \(String(describing: error), privacy: .public)")
        }
    }
}
