import Foundation
import CryptoKit

/// At-rest obfuscation for inline secrets written to `config.toml` via the
/// Settings UI (currently the `api_key` field of the four non-shared-CLI
/// vendors: ZAI, OpenRouter, Kimi, Gemini).
///
/// **Threat model — read this before assuming this is real encryption.**
///
/// The symmetric key is derived from a constant baked into the binary. Anyone
/// with the `.app` can extract it in seconds via `strings` or Hopper. This
/// scheme protects only against:
///
///   - Casual reading of `config.toml` itself (e.g. the user screen-shares
///     the file, or pastes it into a chat by mistake).
///   - Backup exfiltration by an attacker who has the file but NOT the app.
///
/// It does NOT protect against:
///
///   - Malware running as the user (it can call `SecretBox.decrypt` or just
///     read the key out of the binary).
///   - Anyone with both the config file AND the app binary.
///
/// Honest comparison vs. the previous status quo (plaintext at `0o600`):
/// strictly better in the two scenarios above; equivalent everywhere else.
/// Migrating to Keychain (`SecItemAdd`) is the real fix and remains on the
/// roadmap — see `KeychainCredentialReader` for the pattern that already
/// protects Anthropic + Codex credentials.
///
/// Format: `enc:v1:` + base64( nonce(12B) || ciphertext || tag(16B) ).
/// Nonce is randomized per encrypt call → encrypting the same plaintext
/// twice produces different ciphertexts (correct AES-GCM usage).
public enum SecretBox {
    /// Wire-format prefix. Bumped only on cryptographic scheme changes
    /// (e.g. migrating from AES-GCM to ChaCha20-Poly1305).
    public static let prefix = "enc:v1:"

    /// Hardcoded app-specific passphrase. SHA-256'd into a 256-bit
    /// `SymmetricKey`. NOT a secret in any meaningful sense — see the threat
    /// model in the type doc above.
    private static let appPassphrase = "ai-taskbar/v0.3:settings-secret-v1"

    // `SymmetricKey` is not formally `Sendable` in CryptoKit, but it's
    // effectively immutable after init (no mutating API surfaces). Marking
    // `nonisolated(unsafe)` is honest: the value is a process-wide constant
    // derived from a literal, with no writer after initialization.
    nonisolated(unsafe) private static let key: SymmetricKey = {
        let digest = SHA256.hash(data: Data(appPassphrase.utf8))
        return SymmetricKey(data: digest)
    }()

    /// Encrypts `plaintext` and returns the wire-format string suitable for
    /// writing into a TOML `api_key = "..."` slot. Non-deterministic.
    public static func encrypt(_ plaintext: String) throws -> String {
        do {
            let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
            // `.combine` is nonce || ciphertext || tag in one contiguous blob.
            guard let combined = sealed.combined else {
                throw AppError.other("SecretBox: AES-GCM refused to combine (unexpected)")
            }
            return prefix + combined.base64EncodedString()
        } catch let err as AppError {
            throw err
        } catch {
            throw AppError.other("SecretBox.encrypt: \(error)")
        }
    }

    /// Decrypts a wire-format string back to plaintext. Throws on any
    /// tampering or malformed input — GCM authentication tag catches both.
    /// Returns `nil` if `encoded` isn't a SecretBox payload (i.e. plaintext
    /// value still in an old config) — callers use that to keep reading
    /// legacy plaintext transparently.
    public static func decryptIfPresent(_ encoded: String) throws -> String? {
        guard encoded.hasPrefix(prefix) else { return nil }
        let payload = String(encoded.dropFirst(prefix.count))
        guard let combined = Data(base64Encoded: payload) else {
            throw AppError.other("SecretBox: malformed base64 in encrypted value")
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealed, using: key)
            return String(data: plaintext, encoding: .utf8)
        } catch {
            throw AppError.other("SecretBox.decrypt: \(error)")
        }
    }

    /// Returns true when `value` is a SecretBox-encrypted payload. Used by
    /// `ConfigLoader.load()` to decide whether to decrypt before handing the
    /// value to the TOML decoder.
    public static func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }
}
