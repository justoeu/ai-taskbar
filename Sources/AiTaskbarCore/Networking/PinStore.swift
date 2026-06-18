import Foundation
import os.lock

/// On-disk store of TLS pin hashes (Trust-On-First-Use). One file per host
/// under `~/Library/Application Support/ai-taskbar/pins/<host>.txt`. Each
/// file contains a single base64 SHA256 SPKI hash. Locked to `0o600`.
///
/// Concurrency: `memo` is guarded by a single `OSAllocatedUnfairLock` —
/// same primitive `KeychainCredentialReader` already uses. File I/O happens
/// OUTSIDE the lock so a slow disk read under contention doesn't block
/// unrelated callers from cached lookups.
public final class PinStore: @unchecked Sendable {
    public let baseDir: URL
    private let memo = OSAllocatedUnfairLock(initialState: [String: String]())

    public init(baseDir: URL) {
        self.baseDir = baseDir
    }

    public static func defaultStore() throws -> PinStore {
        let dir = try Paths.applicationSupport()
            .appendingPathComponent("pins", isDirectory: true)
        try Paths.ensureDir(dir)
        // 0o700 — pin files are pseudo-secrets (revealing which hosts the
        // user talks to). Inherits from the parent Application Support dir
        // which is already 0o700, but be explicit.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: dir.path
        )
        return PinStore(baseDir: dir)
    }

    public func get(host: String) -> String? {
        let key = host.lowercased()
        // Fast path: cache hit. The `withLock` body is a single dict lookup,
        // no system call inside the critical section.
        if let cached = memo.withLock({ $0[key] }) {
            return cached
        }
        // Slow path: disk read OUTSIDE the lock so concurrent lookups for
        // other hosts don't serialize on file I/O.
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty
        else { return nil }
        // Memoize. A concurrent `set` could have populated the entry while
        // we were reading — last writer wins, which is fine: both are the
        // correct pin for this host (TOFU invariant).
        memo.withLock { $0[key] = s }
        return s
    }

    public func set(host: String, hash: String) {
        let key = host.lowercased()
        memo.withLock { $0[key] = hash }
        try? AtomicFileWrite.write(Data(hash.utf8), to: fileURL(for: key),
                                   permissions: 0o600)
    }

    public func clear(host: String) {
        let key = host.lowercased()
        memo.withLock { $0.removeValue(forKey: key) }
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    private func fileURL(for host: String) -> URL {
        baseDir.appendingPathComponent("\(host).txt")
    }
}
