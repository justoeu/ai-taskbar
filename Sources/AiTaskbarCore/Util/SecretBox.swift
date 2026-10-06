import Foundation
import CryptoKit

/// At-rest encryption for inline secrets written to `config.toml` (every
/// vendor `api_key` and the TypeSafe console session).
///
/// **Threat model — read this before assuming more than it gives.**
///
/// `enc:v2:` (current): AES-GCM with a key derived by HKDF-SHA256 from a
/// constant in the binary AND this Mac's hardware UUID (`MachineIdentity`).
/// The source is public, so the constant is not a secret, and the UUID is not
/// one either — any local process, `ioreg`, System Information exports and
/// Time Machine metadata expose it. What binding to it buys:
///
///   - Protects: the file ON ITS OWN leaving this Mac (pasted, shared on
///     screen, attached, copied elsewhere without the machine's context).
///   - Does NOT protect: malware running as the user here, or anyone holding
///     a full disk image / Time Machine backup of this Mac (it carries the
///     UUID). On a logic-board swap / new Mac keys must be re-entered there —
///     preferences are unaffected.
///
/// `enc:v1:` (legacy): key from the constant alone — obfuscation only. Still
/// decrypted, never written while the UUID is readable; `ConfigLoader.
/// upgradeSecretsIfNeeded` rewrites v1 and plaintext values as v2 at launch
/// (without a backup file, which would keep them on disk).
///
/// Keychain was considered and declined (2026-10-05): this Mac's login
/// keychain lost items unexplained, and losing the key would lose every
/// secret; the UUID cannot be "lost" short of new hardware.
///
/// Format: prefix + base64( nonce(12B) || ciphertext || tag(16B) ).
/// Nonce is randomized per encrypt call → encrypting the same plaintext
/// twice produces different ciphertexts (correct AES-GCM usage).
public enum SecretBox {
    /// Legacy wire-format prefix (key from the constant alone). Still read;
    /// written only when no hardware UUID can be read.
    public static let prefix = "enc:v1:"
    /// Machine-bound format (see the type doc).
    public static let prefixV2 = "enc:v2:"
    private static let saltV2 = Data("ai-taskbar.secretbox.v2".utf8)

    /// Hardcoded app-specific passphrase. SHA-256'd into a 256-bit
    /// `SymmetricKey`. NOT a secret in any meaningful sense — see the threat
    /// model in the type doc above.
    private static let appPassphrase = "ai-taskbar/v0.3:settings-secret-v1"

    // `SymmetricKey` now conforms to `Sendable` in CryptoKit, so the
    // `nonisolated(unsafe)` this used to carry is no longer needed — the
    // compiler can prove what the old comment asserted by hand.
    private static let key: SymmetricKey = {
        let digest = SHA256.hash(data: Data(appPassphrase.utf8))
        return SymmetricKey(data: digest)
    }()

    /// The v2 key for one machine: HKDF-SHA256 over the binary constant,
    /// salted, with the hardware UUID as `info`.
    static func machineKey(_ machineID: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: saltV2,
                               info: Data(machineID.utf8), outputByteCount: 32)
    }

    /// Encrypts `plaintext` and returns the wire-format string suitable for
    /// writing into a TOML `api_key = "..."` slot. Non-deterministic. Writes
    /// `enc:v2:` bound to `machineID`; only when no machine id can be read
    /// does it fall back to `enc:v1:` (still better than plaintext).
    public static func encrypt(_ plaintext: String,
                               machineID: String? = MachineIdentity.current) throws -> String {
        let usedKey = machineID.map(machineKey) ?? key
        let usedPrefix = machineID == nil ? prefix : prefixV2
        if machineID == nil {
            AppLog.config.warning("SecretBox: no hardware UUID — writing legacy enc:v1:")
        }
        do {
            let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: usedKey)
            // `.combine` is nonce || ciphertext || tag in one contiguous blob.
            guard let combined = sealed.combined else {
                throw AppError.other("SecretBox: AES-GCM refused to combine (unexpected)")
            }
            return usedPrefix + combined.base64EncodedString()
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
    public static func decryptIfPresent(_ encoded: String,
                                        machineID: String? = MachineIdentity.current) throws -> String? {
        let usedKey: SymmetricKey
        let payload: String
        if encoded.hasPrefix(prefixV2) {
            guard let machineID else {
                throw AppError.other("SecretBox: enc:v2: value but no hardware UUID to derive its key")
            }
            usedKey = machineKey(machineID)
            payload = String(encoded.dropFirst(prefixV2.count))
        } else if encoded.hasPrefix(prefix) {
            usedKey = key
            payload = String(encoded.dropFirst(prefix.count))
        } else {
            return nil
        }
        guard let combined = Data(base64Encoded: payload) else {
            throw AppError.other("SecretBox: malformed base64 in encrypted value")
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            // A v2 value from another Mac fails here (GCM tag mismatch).
            let plaintext = try AES.GCM.open(sealed, using: usedKey)
            return String(data: plaintext, encoding: .utf8)
        } catch {
            throw AppError.other("SecretBox.decrypt: \(error)")
        }
    }

    /// Returns true when `value` is a SecretBox-encrypted payload. Used by
    /// `ConfigLoader.load()` to decide whether to decrypt before handing the
    /// value to the TOML decoder.
    public static func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(prefix) || value.hasPrefix(prefixV2)
    }

    /// True when `value` is already in the format `encrypt` would write now
    /// (v2 when a machine id exists). Plaintext and v1 need an upgrade.
    public static func isCurrentFormat(_ value: String, machineID: String? = MachineIdentity.current) -> Bool {
        machineID == nil ? isEncrypted(value) : value.hasPrefix(prefixV2)
    }
}
