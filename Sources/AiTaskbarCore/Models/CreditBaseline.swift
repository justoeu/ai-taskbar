import Foundation
import os.lock

/// Pure math behind the credits progress bar.
///
/// The Codex usage endpoint reports only the REMAINING credit balance
/// (`credits.balance`). There is no "granted total" anywhere in the payload —
/// `spend_control.individual_limit` is null and `promo` is null on a real Pro
/// account — so a percentage needs a denominator we derive ourselves: the
/// highest balance ever observed. A balance ABOVE that high-water mark can
/// only mean a top-up, which re-baselines the bar to 0% consumed.
///
/// The honest limitation: on the very first observation consumed reads 0%,
/// because nothing tells us how much was spent before the app started
/// watching. The bar becomes meaningful from that point forward and is exact
/// after the next top-up.
public enum CreditBaselineMath {
    /// The denominator to use after observing `balance`. Grows on a top-up,
    /// never shrinks while credits are being consumed.
    public static func updatedPeak(stored: Double?, balance: Double) -> Double {
        let observed = sanitized(balance)
        guard let stored, stored.isFinite, stored > observed else { return observed }
        return stored
    }

    /// Share of the baseline already consumed, 0...100.
    ///
    /// nil when the answer is unknowable rather than zero: no usable
    /// denominator (peak <= 0 or non-finite), or a non-finite balance. A
    /// garbled balance must read as "no bar", never as a confident 0% or a
    /// red 100%, and NaN must never reach `ProgressView`.
    /// A negative balance is real overdraft and does read as fully consumed.
    public static func consumedPercent(peak: Double, balance: Double) -> Double? {
        guard peak.isFinite, peak > 0, balance.isFinite else { return nil }
        let remaining = max(balance, 0)
        let consumed = (peak - min(remaining, peak)) / peak * 100
        return min(max(consumed, 0), 100)
    }

    /// Negative or non-finite balances never raise the denominator.
    private static func sanitized(_ balance: Double) -> Double {
        guard balance.isFinite, balance > 0 else { return 0 }
        return balance
    }
}

/// The persisted high-water mark for one vendor's credit balance.
public struct CreditBaseline: Sendable, Equatable, Codable {
    /// Highest balance observed so far — the progress bar's denominator.
    public let peak: Double
    /// When `peak` was last raised, for diagnostics.
    public let updatedAt: TimeInterval

    public init(peak: Double, updatedAt: TimeInterval) {
        self.peak = peak
        self.updatedAt = updatedAt
    }

    /// Validates on the way in. The synthesized decoder would accept a NaN or
    /// negative `peak` from a corrupted or hand-edited file and that value
    /// would then stick forever, poisoning every percentage. Rejecting it makes
    /// `load()` return nil, which re-seeds from the next observed balance.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawPeak = try c.decode(Double.self, forKey: .peak)
        guard rawPeak.isFinite, rawPeak >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .peak, in: c,
                debugDescription: "peak must be a finite, non-negative quantity")
        }
        peak = rawPeak
        updatedAt = try c.decode(TimeInterval.self, forKey: .updatedAt)
    }
}

/// Persists the credit high-water mark across launches in
/// `~/Library/Application Support/ai-taskbar/credits/<vendor>.json`.
///
/// Not a secret (a remaining-credit count), so it carries no `0o600`
/// requirement of its own; the enclosing Application Support directory is
/// already `0700`. Failures are best-effort by design: losing the baseline
/// costs a re-seeded bar on the next refresh, never a wrong number, so a
/// read/write error must not fail the vendor's usage fetch.
public final class CreditBaselineStore: Sendable {
    public let vendor: VendorId
    public let baseDir: URL
    private let cached = OSAllocatedUnfairLock(initialState: CreditBaseline?.none)
    /// Serializes the whole read-modify-write in `recordAndPeak`. `cached`
    /// alone is not enough: it is released between the load and the save, so
    /// two overlapping refreshes could interleave and the later, smaller
    /// balance would overwrite a top-up — permanently under-seeding the
    /// denominator. A plain mutex, not the unfair lock, because this one is
    /// held across file I/O.
    private let writeGate = NSLock()

    public init(vendor: VendorId, baseDir: URL) {
        self.vendor = vendor
        self.baseDir = baseDir
    }

    public static func defaultFor(_ vendor: VendorId) throws -> CreditBaselineStore {
        let dir = try Paths.applicationSupport()
            .appendingPathComponent("credits", isDirectory: true)
        try Paths.ensureDir(dir)
        return CreditBaselineStore(vendor: vendor, baseDir: dir)
    }

    public var fileURL: URL {
        baseDir.appendingPathComponent("\(vendor.rawValue).json")
    }

    /// Folds `balance` into the baseline and returns the denominator to use.
    /// Writes only when the peak actually moves, so a steadily draining
    /// balance costs no disk I/O per refresh.
    @discardableResult
    public func recordAndPeak(balance: Double, at now: Date = .init()) -> Double {
        writeGate.lock()
        defer { writeGate.unlock() }
        let stored = load()?.peak
        let peak = CreditBaselineMath.updatedPeak(stored: stored, balance: balance)
        if stored == nil || peak > (stored ?? 0) {
            save(CreditBaseline(peak: peak, updatedAt: now.timeIntervalSince1970))
        }
        return peak
    }

    public func load() -> CreditBaseline? {
        if let hit = cached.withLock({ $0 }) { return hit }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? SharedCoders.decoder.decode(CreditBaseline.self, from: data)
        else { return nil }
        cached.withLock { $0 = decoded }
        return decoded
    }

    /// Best-effort: a baseline we fail to persist is re-seeded next launch.
    /// Internal because a non-finite `peak` would make the encode fail
    /// silently; `recordAndPeak` is the only sanctioned entry point and it
    /// cannot produce one.
    internal func save(_ baseline: CreditBaseline) {
        guard baseline.peak.isFinite, baseline.peak >= 0 else { return }
        cached.withLock { $0 = baseline }
        guard let data = try? SharedCoders.encoder.encode(baseline) else { return }
        try? AtomicFileWrite.write(data, to: fileURL)
    }

    /// Drops the baseline (both memory and disk). Used by tests and by a
    /// future "recalibrate" affordance.
    public func reset() {
        cached.withLock { $0 = nil }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
