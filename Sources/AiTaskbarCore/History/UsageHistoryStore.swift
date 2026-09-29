import Foundation
import os.lock

/// Append-only ring of per-vendor max-utilization samples persisted as JSONL
/// in `~/Library/Application Support/ai-taskbar/history/<vendor>.jsonl`.
/// Each line is `{"at": <unix-seconds>, "max": <double>}`.
///
/// Thread safety: callers may invoke `append`/`load`/`compact` from different
/// queues; an internal `OSAllocatedUnfairLock` serializes file-handle access
/// (same primitive `KeychainCredentialReader` uses — one cheap kernel lock,
/// value-typed state, no `NSLock`/`var` pair to keep in sync).
/// Performance: the write `FileHandle` is held open for the lifetime of the
/// store so each `append` is a single `write(_:)` syscall instead of
/// open+seek+write+close.
public final class UsageHistoryStore: @unchecked Sendable {
    public let vendor: VendorId
    public let baseDir: URL
    public let retention: TimeInterval

    /// Guarded state — only the `writeHandle` is mutable. Held under the
    /// unfair lock so concurrent `append`s serialize cleanly.
    private struct LockedState {
        var writeHandle: FileHandle?
        /// True while appends keep failing; gates the one-shot log.
        var appendFailing = false
    }
    private let state = OSAllocatedUnfairLock(initialState: LockedState())
    public static let defaultRetention: TimeInterval = 90 * 86_400 // 90 days

    public init(vendor: VendorId, baseDir: URL, retention: TimeInterval = defaultRetention) {
        self.vendor = vendor
        self.baseDir = baseDir
        self.retention = retention
    }

    public static func defaultFor(_ vendor: VendorId) throws -> UsageHistoryStore {
        let dir = try Paths.applicationSupport()
            .appendingPathComponent("history", isDirectory: true)
        try Paths.ensureDir(dir)
        return UsageHistoryStore(vendor: vendor, baseDir: dir)
    }

    public var fileURL: URL {
        baseDir.appendingPathComponent("\(vendor.rawValue).jsonl")
    }

    public struct Sample: Sendable, Equatable, Codable {
        public let at: TimeInterval
        public let max: Double
        /// `max` is sanitized via `UtilizationPercent` here AND when a line
        /// is decoded, so an absurd value is neither persisted nor replayed
        /// from a file an older build wrote (it would otherwise sit in the
        /// 90-day history and crash every render of it).
        public init(at: TimeInterval, max: Double) {
            self.at = at
            self.max = UtilizationPercent.sanitized(max)
        }

        private enum CodingKeys: String, CodingKey { case at, max }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(at: try c.decode(TimeInterval.self, forKey: .at),
                      max: try c.decode(Double.self, forKey: .max))
        }
    }

    // MARK: - Append

    /// Best-effort: a failed append never throws or crashes (history is
    /// telemetry), but it is no longer silent. Returns `false` when the sample
    /// did not reach disk, and logs the first failure of a streak so a broken
    /// history dir shows up in Console.app without one line per refresh
    /// (CQ-AUR-003).
    @discardableResult
    public func append(maxUtilization: Double, at: Date = .init()) -> Bool {
        let sample = Sample(at: at.timeIntervalSince1970, max: maxUtilization)
        let line: Data
        do {
            line = try SharedCoders.encoder.encode(sample) + [0x0a]
        } catch {
            return recordAppendOutcome(failure: "encode: \(error)")
        }
        let failure: String? = state.withLock { s in
            guard let handle = ensureWriteHandleLocked(&s.writeHandle) else {
                return "cannot open \(fileURL.lastPathComponent) for writing"
            }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                return nil
            } catch {
                // If the file got moved out from under us, drop and lazily reopen.
                try? handle.close()
                s.writeHandle = nil
                return "write: \(error)"
            }
        }
        return recordAppendOutcome(failure: failure)
    }

    /// Tracks the failure streak and logs only its first failure.
    private func recordAppendOutcome(failure: String?) -> Bool {
        let firstOfStreak = state.withLock { s -> Bool in
            let first = failure != nil && !s.appendFailing
            s.appendFailing = failure != nil
            return first
        }
        if firstOfStreak, let failure {
            AppLog.lifecycle.error(
                "history append failed for \(self.vendor.rawValue, privacy: .public): \(failure, privacy: .public)")
        }
        return failure == nil
    }

    /// Lazily opens the write handle on first append. Creates the file with
    /// `0o600` perms if it doesn't exist. Returns nil if the open fails.
    /// MUST be called inside `state.withLock`.
    private func ensureWriteHandleLocked(_ handle: inout FileHandle?) -> FileHandle? {
        if let h = handle { return h }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil,
                          attributes: [.posixPermissions: NSNumber(value: 0o600)])
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        return handle
    }

    // MARK: - Read

    public func load(since: Date) -> [Sample] {
        // Read-only mmap doesn't need the write-handle lock — the file is
        // append-only and `Data(contentsOf:)` gives us a snapshot.
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { return [] }
        let cutoff = since.timeIntervalSince1970
        var out: [Sample] = []
        out.reserveCapacity(2048)
        // Decode from the mmap slice without allocating a fresh Data(line)
        // copy per sample (N1-NEX-006). ContiguousBytes → JSONDecoder.
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var start = 0
            let n = raw.count
            while start < n {
                var end = start
                while end < n && base[end] != 0x0a { end += 1 }
                let len = end - start
                if len > 0 {
                    let slice = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                                     count: len,
                                     deallocator: .none)
                    if let sample = try? SharedCoders.decoder.decode(Sample.self, from: slice),
                       sample.at >= cutoff {
                        out.append(sample)
                    }
                }
                start = end + 1
            }
        }
        // Defensive sort — the file is append-only and time-ordered, but
        // protect downstream chart/sparkline code from any future skew.
        out.sort { $0.at < $1.at }
        return out
    }

    public func load(between start: Date, and end: Date) -> [Sample] {
        let samples = load(since: start)
        let endCutoff = end.timeIntervalSince1970
        return samples.filter { $0.at <= endCutoff }
    }

    // MARK: - Compact

    /// Removes entries older than `retention`. Holds the lock across the
    /// entire close → read → filter → replace so concurrent `append` cannot
    /// write lines that the subsequent atomic rewrite would drop (RACE-HER-001).
    public func compact() {
        state.withLock { s in
            try? s.writeHandle?.close()
            s.writeHandle = nil
            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { return }
            let cutoff = Date.now.addingTimeInterval(-retention).timeIntervalSince1970
            var kept = Data()
            for line in data.split(separator: 0x0a) {
                guard let sample = try? SharedCoders.decoder.decode(Sample.self, from: Data(line)),
                      sample.at >= cutoff else { continue }
                kept.append(line)
                kept.append(0x0a)
            }
            do {
                try AtomicFileWrite.write(kept, to: fileURL, permissions: 0o600)
            } catch {
                // Don't swallow — silent fail lets JSONL grow without bound
                // (LEAK-HYD-001). Next compact will retry.
                AppLog.lifecycle.error(
                    "history compact write failed for \(self.vendor.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            // Handle stays nil; next append reopens the post-replace inode.
        }
    }

    deinit {
        // Close outside the lock — the lock itself is being torn down.
        if let h = state.withLock({ $0.writeHandle }) {
            try? h.close()
        }
    }
}

