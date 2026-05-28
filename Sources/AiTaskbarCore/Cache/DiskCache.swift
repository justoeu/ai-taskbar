import Foundation

/// Per-vendor on-disk cache. Stores the raw payload (not the parsed snapshot)
/// so a schema change in our parsers does not invalidate cached bytes.
///
/// Files in `<caches>/<vendor>/`:
///   - `usage.json`     — last successful payload
///   - `.stale`         — marker, present iff last fetch failed
///   - `.last_error`    — two lines: status, body excerpt
public struct DiskCache: Sendable {
    public let vendor: VendorId
    public let baseDir: URL
    public let ttl: TimeInterval
    public let maxStale: TimeInterval

    public init(vendor: VendorId,
                baseDir: URL,
                ttl: TimeInterval = 150,
                maxStale: TimeInterval = 7 * 24 * 60 * 60) {
        self.vendor = vendor
        self.baseDir = baseDir
        self.ttl = ttl
        self.maxStale = maxStale
    }

    /// Builds a cache rooted at the user's standard Caches/<vendor>/ dir.
    /// `ttl` defaults to 150 s (matches the default `refresh_interval_seconds`)
    /// but callers should pass the active interval to keep cache TTL aligned
    /// with how often the scheduler actually fires — otherwise popover opens
    /// between scheduled refreshes can burn extra network calls.
    public static func defaultFor(_ vendor: VendorId,
                                  ttl: TimeInterval = 150) throws -> DiskCache {
        let dir = try Paths.cacheDir(for: vendor)
        return DiskCache(vendor: vendor, baseDir: dir, ttl: ttl)
    }

    private var payloadURL: URL  { baseDir.appendingPathComponent("usage.json") }
    private var staleURL:   URL  { baseDir.appendingPathComponent(".stale") }
    private var errorURL:   URL  { baseDir.appendingPathComponent(".last_error") }

    // MARK: - Reads

    public func payloadAge() -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: payloadURL.path),
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        return Date.now.timeIntervalSince(mtime)
    }

    public func freshPayload() -> Data? {
        guard let age = payloadAge(), age <= ttl else { return nil }
        return try? Data(contentsOf: payloadURL)
    }

    public func anyPayload() -> Data? {
        guard let age = payloadAge(), age <= maxStale else { return nil }
        return try? Data(contentsOf: payloadURL)
    }

    public func isStale() -> Bool {
        FileManager.default.fileExists(atPath: staleURL.path)
    }

    public func lastError() -> FetchError? {
        guard let txt = try? String(contentsOf: errorURL, encoding: .utf8) else { return nil }
        let lines = txt.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2, let status = Int(lines[0]) else { return nil }
        return FetchError(status: status, body: String(lines[1]))
    }

    // MARK: - Writes

    public func writePayload(_ data: Data) throws {
        // Cache files may contain low-grade PII (e.g. account labels) so lock
        // them down to user-only. Defense in depth — `~/Library/Caches/` is
        // already user-owned but umask defaults leave it at 0o644.
        try AtomicFileWrite.write(data, to: payloadURL, permissions: 0o600)
        // Successful fetch — clear the stale markers if present.
        try? FileManager.default.removeItem(at: staleURL)
        try? FileManager.default.removeItem(at: errorURL)
    }

    public func markStale() {
        try? Data().write(to: staleURL)
    }

    public func markFailed(_ error: FetchError) {
        markStale()
        let txt = "\(error.status)\n\(error.body.prefix(500))"
        try? AtomicFileWrite.write(Data(txt.utf8), to: errorURL, permissions: 0o600)
    }
}
