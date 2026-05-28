import Foundation

/// Append-only ring of per-vendor max-utilization samples persisted as JSONL
/// in `~/Library/Application Support/ai-taskbar/history/<vendor>.jsonl`.
/// Each line is `{"at": <unix-seconds>, "max": <double>}`.
///
/// Thread safety: callers may invoke `append`/`load`/`compact` from different
/// queues; an internal `NSLock` serializes file-handle access.
/// Performance: the write `FileHandle` is held open for the lifetime of the
/// store so each `append` is a single `write(_:)` syscall instead of
/// open+seek+write+close.
public final class UsageHistoryStore: @unchecked Sendable {
    public let vendor: VendorId
    public let baseDir: URL
    public let retention: TimeInterval

    private let lock = NSLock()
    private var writeHandle: FileHandle?

    public init(vendor: VendorId, baseDir: URL, retention: TimeInterval = 7 * 86_400) {
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
        public init(at: TimeInterval, max: Double) {
            self.at = at
            self.max = max
        }
    }

    // MARK: - Append

    public func append(maxUtilization: Double, at: Date = .init()) {
        let sample = Sample(at: at.timeIntervalSince1970, max: maxUtilization)
        guard var line = try? SharedCoders.encoder.encode(sample) else { return }
        line.append(0x0a)
        lock.lock()
        defer { lock.unlock() }
        guard let handle = ensureWriteHandleLocked() else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // If the file got moved out from under us, drop and lazily reopen.
            try? handle.close()
            writeHandle = nil
        }
    }

    /// Lazily opens the write handle on first append. Creates the file with
    /// `0o600` perms if it doesn't exist. Returns nil if the open fails.
    private func ensureWriteHandleLocked() -> FileHandle? {
        if let h = writeHandle { return h }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil,
                          attributes: [.posixPermissions: NSNumber(value: 0o600)])
        }
        writeHandle = try? FileHandle(forWritingTo: fileURL)
        return writeHandle
    }

    // MARK: - Read

    public func load(since: Date) -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { return [] }
        let cutoff = since.timeIntervalSince1970
        var out: [Sample] = []
        out.reserveCapacity(2048)
        for line in data.split(separator: 0x0a) {
            guard let sample = try? SharedCoders.decoder.decode(Sample.self, from: Data(line))
            else { continue }
            if sample.at >= cutoff { out.append(sample) }
        }
        // Defensive sort — the file is append-only and time-ordered, but
        // protect downstream chart/sparkline code from any future skew.
        out.sort { $0.at < $1.at }
        return out
    }

    // MARK: - Compact

    /// Removes entries older than `retention`. Closes the write handle for
    /// the duration so the atomic replace can swap files cleanly.
    public func compact() {
        lock.lock()
        defer { lock.unlock() }
        try? writeHandle?.close()
        writeHandle = nil
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { return }
        let cutoff = Date.now.addingTimeInterval(-retention).timeIntervalSince1970
        var kept = Data()
        for line in data.split(separator: 0x0a) {
            guard let sample = try? SharedCoders.decoder.decode(Sample.self, from: Data(line)),
                  sample.at >= cutoff else { continue }
            kept.append(line)
            kept.append(0x0a)
        }
        try? AtomicFileWrite.write(kept, to: fileURL, permissions: 0o600)
    }

    deinit {
        try? writeHandle?.close()
    }
}
