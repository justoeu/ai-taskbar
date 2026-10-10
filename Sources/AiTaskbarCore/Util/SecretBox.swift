import Foundation
import CryptoKit

/// At-rest encryption for inline secrets written to `config.toml` (every
/// vendor `api_key` and the TypeSafe console session).
///
/// **Threat model — read this before assuming more than it gives.**
///
/// `enc:v2:` (current): AES-GCM with a key derived by HKDF-SHA256 from this
/// Mac's hardware UUID (`MachineIdentity`) under a fixed public salt and
/// label, each value also bound to its config field. The source is public,
/// so salt and label are not secrets, and the UUID is not one either — any
/// local process, `ioreg`, System Information exports and Time Machine
/// metadata expose it. What binding to it buys:
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
///
/// v2 key and binding: HKDF-SHA256 with the hardware UUID as the input key
/// material, a fixed salt and a fixed `info` label. Each v2 value is also
/// bound to the config field it lives in (`"section.key"`) as AES-GCM
/// additional authenticated data, so a value moved into another field fails
/// the tag check instead of opening there. v1 has no field binding.
public enum SecretBox {
    /// Legacy wire-format prefix (key from the constant alone). Still read;
    /// written only when no hardware UUID can be read.
    public static let prefix = "enc:v1:"
    /// Machine-bound format (see the type doc).
    public static let prefixV2 = "enc:v2:"
    private static let saltV2 = Data("ai-taskbar.secretbox.v2".utf8)
    private static let infoV2 = Data("ai-taskbar.secretbox.v2/config-secret-key".utf8)

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

    /// The v2 key for one machine: HKDF-SHA256 with the hardware UUID as the
    /// input key material (the machine-specific part), a fixed salt and a
    /// fixed `info` label.
    static func machineKey(_ machineID: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(machineID.utf8)),
                               salt: saltV2, info: infoV2, outputByteCount: 32)
    }

    /// Additional authenticated data binding a v2 value to its field.
    private static func fieldBinding(_ field: String) -> Data {
        Data("ai-taskbar.config-field:\(field)".utf8)
    }

    /// Encrypts `plaintext` for the config field `field` (`"section.key"`,
    /// e.g. `"zai.api_key"`) and returns the wire-format string suitable for
    /// writing into that TOML slot. Non-deterministic. Writes `enc:v2:` bound
    /// to `machineID` and `field`; only when no machine id can be read does it
    /// fall back to `enc:v1:` (still better than plaintext, no field binding).
    public static func encrypt(_ plaintext: String,
                               field: String,
                               machineID: String? = MachineIdentity.current) throws -> String {
        do {
            if let machineID {
                let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: machineKey(machineID),
                                              authenticating: fieldBinding(field))
                return prefixV2 + (try combined(sealed))
            }
            AppLog.config.warning("SecretBox: no hardware UUID — writing legacy enc:v1:")
            let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
            return prefix + (try combined(sealed))
        } catch let err as AppError {
            throw err
        } catch {
            throw AppError.other("SecretBox.encrypt: \(error)")
        }
    }

    /// `.combined` is nonce || ciphertext || tag in one contiguous blob.
    private static func combined(_ sealed: AES.GCM.SealedBox) throws -> String {
        guard let combined = sealed.combined else {
            throw AppError.other("SecretBox: AES-GCM refused to combine (unexpected)")
        }
        return combined.base64EncodedString()
    }

    /// Decrypts a wire-format string read from the config field `field` back
    /// to plaintext. Throws on any tampering or malformed input — the GCM tag
    /// catches both, and for v2 also a value sealed for another field or
    /// another Mac. Returns `nil` if `encoded` isn't a SecretBox payload
    /// (i.e. plaintext value still in an old config) — callers use that to
    /// keep reading legacy plaintext transparently.
    public static func decryptIfPresent(_ encoded: String,
                                        field: String,
                                        machineID: String? = MachineIdentity.current) throws -> String? {
        let usedKey: SymmetricKey
        let payload: String
        let aad: Data?
        if encoded.hasPrefix(prefixV2) {
            guard let machineID else {
                throw AppError.other("SecretBox: enc:v2: value but no hardware UUID to derive its key")
            }
            usedKey = machineKey(machineID)
            payload = String(encoded.dropFirst(prefixV2.count))
            aad = fieldBinding(field)
        } else if encoded.hasPrefix(prefix) {
            usedKey = key
            payload = String(encoded.dropFirst(prefix.count))
            aad = nil
        } else {
            return nil
        }
        guard let combined = Data(base64Encoded: payload) else {
            throw AppError.other("SecretBox: malformed base64 in encrypted value")
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            // A v2 value from another Mac or another field fails here (tag).
            let plaintext: Data
            if let aad {
                plaintext = try AES.GCM.open(sealed, using: usedKey, authenticating: aad)
            } else {
                plaintext = try AES.GCM.open(sealed, using: usedKey)
            }
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
