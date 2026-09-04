import Foundation
import os

public enum CacheScope: String, Codable, Sendable, Equatable {
    case usage
    case status

    fileprivate var defaultMaxStale: TimeInterval {
        switch self {
        case .usage: return 7 * 24 * 60 * 60
        case .status: return ServiceStatusWindow.duration
        }
    }
}

/// Per-vendor on-disk cache. Stores the raw payload (not the parsed snapshot)
/// so a schema change in our parsers does not invalidate cached bytes.
///
/// Files in `<caches>/<vendor>/`:
///   - `usage.json`     — last successful payload
///   - `.stale`         — marker, present iff last fetch failed
///   - `.last_error`    — two lines: status, body excerpt
///
/// Concurrency: write/mark paths share a process-wide per-directory lock so
/// concurrent success + failure writers cannot leave payload/stale markers
/// inconsistent (RACE-HER-006).
public struct DiskCache: Sendable {
    public let vendor: VendorId
    public let baseDir: URL
    public let ttl: TimeInterval
    public let maxStale: TimeInterval

    public init(vendor: VendorId,
                baseDir: URL,
                ttl: TimeInterval = 300,
                maxStale: TimeInterval = 7 * 24 * 60 * 60) {
        self.vendor = vendor
        self.baseDir = baseDir
        self.ttl = ttl
        self.maxStale = maxStale
    }

    private func withIOLock<T>(_ body: () throws -> T) rethrows -> T {
        let lock = DiskCacheLocks.lock(for: baseDir.path)
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Builds a cache rooted at the user's standard Caches/<vendor>/ dir.
    /// `ttl` defaults to 300 s (matches the default `refresh_interval_seconds`)
    /// but callers should pass the active interval to keep cache TTL aligned
    /// with how often the scheduler actually fires — otherwise popover opens
    /// between scheduled refreshes can burn extra network calls.
    public static func defaultFor(_ vendor: VendorId,
                                  scope: CacheScope = .usage,
                                  ttl: TimeInterval = 300) throws -> DiskCache {
        let dir = try Paths.cacheDir(for: vendor, scope: scope)
        return DiskCache(
            vendor: vendor,
            baseDir: dir,
            ttl: ttl,
            maxStale: scope.defaultMaxStale
        )
    }

    private var payloadURL: URL  { baseDir.appendingPathComponent("usage.json") }
    private var staleURL:   URL  { baseDir.appendingPathComponent(".stale") }
    private var errorURL:   URL  { baseDir.appendingPathComponent(".last_error") }

    // MARK: - Reads

    public func payloadAge() -> TimeInterval? {
        withIOLock {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: payloadURL.path),
                  let mtime = attrs[.modificationDate] as? Date
            else { return nil }
            return Date.now.timeIntervalSince(mtime)
        }
    }

    /// Single stat+read for the hot cache-hit path (N1-NEX-004).
    public func freshPayloadWithAge() -> (Data, TimeInterval)? {
        withIOLock {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: payloadURL.path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            let age = Date.now.timeIntervalSince(mtime)
            guard age <= ttl,
                  let data = try? Data(contentsOf: payloadURL) else { return nil }
            return (data, age)
        }
    }

    public func freshPayload() -> Data? {
        freshPayloadWithAge()?.0
    }

    public func anyPayloadWithAge() -> (Data, TimeInterval)? {
        withIOLock {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: payloadURL.path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            let age = Date.now.timeIntervalSince(mtime)
            guard age <= maxStale,
                  let data = try? Data(contentsOf: payloadURL) else { return nil }
            return (data, age)
        }
    }

    public func anyPayload() -> Data? {
        anyPayloadWithAge()?.0
    }

    public func isStale() -> Bool {
        withIOLock {
            FileManager.default.fileExists(atPath: staleURL.path)
        }
    }

    public func lastError() -> FetchError? {
        withIOLock {
            guard let txt = try? String(contentsOf: errorURL, encoding: .utf8) else { return nil }
            let lines = txt.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard lines.count == 2, let status = Int(lines[0]) else { return nil }
            return FetchError(status: status, body: String(lines[1]))
        }
    }

    // MARK: - Writes

    public func writePayload(_ data: Data) throws {
        try withIOLock {
            // Cache files may contain low-grade PII (e.g. account labels) so lock
            // them down to user-only. Defense in depth — `~/Library/Caches/` is
            // already user-owned but umask defaults leave it at 0o644.
            try AtomicFileWrite.write(data, to: payloadURL, permissions: 0o600)
            // Successful fetch — clear the stale markers if present.
            try? FileManager.default.removeItem(at: staleURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
    }

    public func markStale() {
        withIOLock {
            try? Data().write(to: staleURL)
        }
    }

    public func markFailed(_ error: FetchError) {
        withIOLock {
            try? Data().write(to: staleURL)
            let txt = "\(error.status)\n\(error.body.prefix(500))"
            try? AtomicFileWrite.write(Data(txt.utf8), to: errorURL, permissions: 0o600)
        }
    }
}

/// Process-wide locks keyed by cache directory path.
enum DiskCacheLocks {
    private static let table = OSAllocatedUnfairLock(initialState: [String: NSLock]())

    static func lock(for path: String) -> NSLock {
        table.withLock { map in
            if let existing = map[path] { return existing }
            let created = NSLock()
            map[path] = created
            return created
        }
    }
}
