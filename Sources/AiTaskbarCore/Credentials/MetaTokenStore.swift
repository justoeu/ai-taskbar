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
/// Stored `SecretBox` `enc:v2:` (machine-bound, field `meta.token_copy`) in
/// a 0600 file inside a 0700 directory: never plaintext, never logged, sent
/// only to the one mint endpoint. `muse logout` (item gone) clears it.
///
/// What this protects, honestly: the file copied OFF this Mac. It is not an
/// ACL — any process running as this user can read it and derive the same
/// key (the hardware UUID is public). That is a step down from the Keychain
/// item, accepted because the alternative is a password prompt after every
/// Muse self-update, which trains users to type their password on reflex.
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

    /// Default location: `~/Library/Application Support/ai-taskbar/credentials/meta-token`,
    /// the directory user-only (0700).
    public static func `default`() throws -> MetaTokenStore {
        let dir = try Paths.applicationSupport().appendingPathComponent("credentials")
        try Paths.ensureDir(dir)
        do {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                                  ofItemAtPath: dir.path)
        } catch {
            throw AppError.io("credentials dir permissions: \(error)")
        }
        return MetaTokenStore(fileURL: dir.appendingPathComponent("meta-token"))
    }

    /// The stored token, or nil when absent, unreadable, tampered or sealed
    /// on another Mac (treated as absent: the Keychain path takes over).
    public func load() -> String? {
        // attributesOfItem does not follow a symlink: a link reads as one.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
            return nil  // absent: the normal state before the first authorized read
        }
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? Int ?? .max) <= Self.maxBytes else {
            AppLog.keychain.error("Muse token copy ignored: not a regular file within \(Self.maxBytes, privacy: .public) bytes")
            return nil
        }
        do {
            let sealed = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
            guard let token = try SecretBox.decryptIfPresent(sealed, field: Self.field, machineID: machineID),
                  token.hasPrefix("dca:") else {
                AppLog.keychain.error("Muse token copy ignored: not a sealed dca: token")
                return nil
            }
            return token
        } catch {
            // Another Mac, tampering or an unreadable file: logged (no
            // secret in the message), then the Keychain path takes over.
            AppLog.keychain.error("Muse token copy unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Seals and writes `token` (0600 at write time). Unchanged tokens are
    /// not rewritten. Without a hardware UUID nothing is stored: a copy
    /// sealed with the legacy machine-independent key would be weaker than
    /// no copy (the Keychain path still works, it just asks again).
    public func save(_ token: String) throws {
        guard token.hasPrefix("dca:"), machineID != nil else { return }
        if load() == token { return }
        let sealed = try SecretBox.encrypt(token, field: Self.field, machineID: machineID)
        try AtomicFileWrite.write(Data(sealed.utf8), to: fileURL, permissions: 0o600)
    }

    /// Removes the copy. True when it is gone afterwards (removed, or never
    /// there); a failed removal is logged and returns false, so a caller
    /// never believes a stale copy was discarded.
    @discardableResult
    public func clear() -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true
        } catch {
            AppLog.keychain.error("Muse token copy not removed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static let maxBytes = 16 << 10
}
