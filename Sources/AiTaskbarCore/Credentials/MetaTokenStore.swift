import Foundation

/// The app's own copy of the Muse CLI's device-code (`dca:`) token, so a
/// Muse self-update does not cost the user a Keychain password.
///
/// Why it exists (measured 2026-10-14/15): the Meta-signed `muse` binary
/// rewrites `ai.meta.dev.credentials` when it updates itself (the launcher
/// checks hourly; 1.4.8 → 1.4.9 in one day), and the rewrite drops every
/// third-party grant. Any reader that depends on the item's ACL — this app,
/// `/usr/bin/security`, CodexBar alike — is asked again after each update.
/// The token itself does not change on those rewrites, so a copy taken on
/// the one authorized read keeps working; the Keychain is consulted again
/// only when Meta rejects the copy (a new `muse login`, a revoked token).
///
/// Stored `SecretBox` `enc:v2:` (bound to this Mac) in a 0600 file, never
/// plaintext, never logged, never sent anywhere but the one mint endpoint.
/// `muse logout` (item gone) clears it.
public struct MetaTokenStore: Sendable {
    public let fileURL: URL
    private let machineID: String?
    /// `SecretBox` field binding: a sealed value from any config slot
    /// cannot be swapped in here, nor this one into a config slot.
    static let field = "meta.token_copy"

    public init(fileURL: URL, machineID: String? = MachineIdentity.current) {
        self.fileURL = fileURL
        self.machineID = machineID
    }

    /// Default location: `~/Library/Application Support/ai-taskbar/credentials/meta-token`.
    public static func `default`() throws -> MetaTokenStore {
        let dir = try Paths.applicationSupport().appendingPathComponent("credentials")
        try Paths.ensureDir(dir)
        return MetaTokenStore(fileURL: dir.appendingPathComponent("meta-token"))
    }

    /// The stored token, or nil when absent, unreadable or sealed on
    /// another Mac (treated as absent: the Keychain path takes over).
    public func load() -> String? {
        guard !Paths.isSymbolicLink(at: fileURL),
              let data = try? Data(contentsOf: fileURL),
              data.count <= 16 << 10,
              let sealed = String(data: data, encoding: .utf8),
              let token = try? SecretBox.decryptIfPresent(sealed, field: Self.field, machineID: machineID),
              token.hasPrefix("dca:")
        else { return nil }
        return token
    }

    /// Seals and writes `token` (0600 at write time). Unchanged tokens are
    /// not rewritten.
    public func save(_ token: String) throws {
        guard token.hasPrefix("dca:") else { return }
        if load() == token { return }
        let sealed = try SecretBox.encrypt(token, field: Self.field, machineID: machineID)
        try AtomicFileWrite.write(Data(sealed.utf8), to: fileURL, permissions: 0o600)
    }

    public func clear() {
        // Best-effort: a stale copy only costs one rejected request.
        try? FileManager.default.removeItem(at: fileURL)
    }
}
