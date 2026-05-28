import Foundation

/// On-disk store of TLS pin hashes (Trust-On-First-Use). One file per host
/// under `~/Library/Application Support/ai-taskbar/pins/<host>.txt`. Each
/// file contains a single base64 SHA256 SPKI hash. Locked to `0o600`.
public final class PinStore: @unchecked Sendable {
    public let baseDir: URL
    private let lock = NSLock()
    private var memo: [String: String] = [:]

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
        lock.lock()
        if let cached = memo[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty
        else { return nil }
        lock.lock()
        memo[key] = s
        lock.unlock()
        return s
    }

    public func set(host: String, hash: String) {
        let key = host.lowercased()
        lock.lock()
        memo[key] = hash
        lock.unlock()
        try? AtomicFileWrite.write(Data(hash.utf8), to: fileURL(for: key),
                                   permissions: 0o600)
    }

    public func clear(host: String) {
        let key = host.lowercased()
        lock.lock()
        memo.removeValue(forKey: key)
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    private func fileURL(for host: String) -> URL {
        baseDir.appendingPathComponent("\(host).txt")
    }
}
