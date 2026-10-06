import Testing
import Foundation
import CryptoKit
@testable import AiTaskbarCore

@Suite("SecretBox — AES-GCM at-rest encryption")
struct SecretBoxTests {
    static let macA = "11111111-2222-3333-4444-555555555555"
    static let macB = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    @Test("round-trip restores the original plaintext")
    func round_trip_restores_plaintext() throws {
        let pt = "sk-or-v1-abc-123-456-789"
        let enc = try SecretBox.encrypt(pt)
        let back = try SecretBox.decryptIfPresent(enc)
        #expect(back == pt)
    }

    @Test("with a machine id, encrypt writes enc:v2 and only that machine reads it")
    func v2_is_machine_bound() throws {
        let enc = try SecretBox.encrypt("sk-bound", machineID: Self.macA)
        #expect(enc.hasPrefix(SecretBox.prefixV2))
        #expect(try SecretBox.decryptIfPresent(enc, machineID: Self.macA) == "sk-bound")
        #expect(throws: AppError.self) {
            _ = try SecretBox.decryptIfPresent(enc, machineID: Self.macB)
        }
        #expect(throws: AppError.self) {
            _ = try SecretBox.decryptIfPresent(enc, machineID: nil)
        }
    }

    @Test("without a machine id, encrypt falls back to enc:v1, readable anywhere")
    func v1_fallback_without_machine_id() throws {
        let enc = try SecretBox.encrypt("sk-legacy", machineID: nil)
        #expect(enc.hasPrefix(SecretBox.prefix))
        #expect(try SecretBox.decryptIfPresent(enc, machineID: Self.macA) == "sk-legacy")
        #expect(try SecretBox.decryptIfPresent(enc, machineID: nil) == "sk-legacy")
    }

    @Test("isCurrentFormat: v2 is current with a machine id; any encryption without one")
    func is_current_format() {
        #expect(SecretBox.isCurrentFormat("enc:v2:AAA", machineID: Self.macA))
        #expect(!SecretBox.isCurrentFormat("enc:v1:AAA", machineID: Self.macA))
        #expect(!SecretBox.isCurrentFormat("plain", machineID: Self.macA))
        #expect(SecretBox.isCurrentFormat("enc:v1:AAA", machineID: nil))
        #expect(!SecretBox.isCurrentFormat("plain", machineID: nil))
    }

    @Test("the real hardware UUID is readable and stable on this Mac")
    func machine_identity_reads_uuid() throws {
        let id = try #require(MachineIdentity.current)
        #expect(id.count == 36)
        #expect(MachineIdentity.hardwareUUID() == id)
    }

    @Test("encrypt is non-deterministic — same plaintext yields different ciphertext")
    func encrypt_non_deterministic() throws {
        let pt = "sk-same-value"
        let a = try SecretBox.encrypt(pt)
        let b = try SecretBox.encrypt(pt)
        #expect(a != b, "AES-GCM with random nonce must produce different ciphertexts")
        // Both decrypt back to the same source, though.
        #expect(try SecretBox.decryptIfPresent(a) == pt)
        #expect(try SecretBox.decryptIfPresent(b) == pt)
    }

    @Test("decryptIfPresent returns nil for plaintext (non-prefixed) input — backward compat")
    func decrypt_returns_nil_for_plaintext() throws {
        #expect(try SecretBox.decryptIfPresent("sk-plaintext-no-prefix") == nil)
        #expect(try SecretBox.decryptIfPresent("") == nil)
    }

    @Test("isEncrypted identifies only enc:v1: / enc:v2: payloads")
    func is_encrypted_prefix_check() {
        #expect(SecretBox.isEncrypted("enc:v1:AAA"))
        #expect(SecretBox.isEncrypted("enc:v2:AAA"))
        #expect(!SecretBox.isEncrypted("enc:v3:AAA"))
        #expect(!SecretBox.isEncrypted("sk-plaintext"))
        #expect(!SecretBox.isEncrypted(""))
        #expect(!SecretBox.isEncrypted("ENC:V1:AAA"))  // case-sensitive
    }

    @Test("tampered ciphertext throws on decrypt (GCM auth tag catches it)")
    func tamper_throws() throws {
        let enc = try SecretBox.encrypt("secret")
        // Flip a byte in the base64 payload — should fail GCM auth.
        var bytes = Array(enc.utf8)
        let prefixLen = SecretBox.prefix.count
        bytes[prefixLen + 2] = (bytes[prefixLen + 2] == 0x41 ? 0x42 : 0x41)  // 'A' <-> 'B'
        let tampered = String(decoding: bytes, as: UTF8.self)
        #expect(throws: AppError.self) {
            _ = try SecretBox.decryptIfPresent(tampered)
        }
    }

    @Test("malformed base64 payload throws")
    func malformed_base64_throws() {
        #expect(throws: AppError.self) {
            _ = try SecretBox.decryptIfPresent("enc:v1:not!valid!base64!!!")
        }
    }

    @Test("empty plaintext round-trips correctly")
    func empty_plaintext() throws {
        let enc = try SecretBox.encrypt("")
        #expect(try SecretBox.decryptIfPresent(enc) == "")
    }

    @Test("unicode plaintext round-trips correctly")
    func unicode_plaintext() throws {
        let pt = "chave-muito-secreta-çÇ-ñÑ-üÜ-日本語"
        let enc = try SecretBox.encrypt(pt)
        #expect(try SecretBox.decryptIfPresent(enc) == pt)
    }

    @Test("long plaintext (8 KB) round-trips correctly")
    func long_plaintext() throws {
        let pt = String(repeating: "x", count: 8192)
        let enc = try SecretBox.encrypt(pt)
        #expect(try SecretBox.decryptIfPresent(enc) == pt)
    }
}
