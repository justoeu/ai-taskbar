import Testing
import Foundation
import CryptoKit
@testable import AiTaskbarCore

@Suite("SecretBox — AES-GCM at-rest obfuscation")
struct SecretBoxTests {
    @Test("round-trip restores the original plaintext")
    func round_trip_restores_plaintext() throws {
        let pt = "sk-or-v1-abc-123-456-789"
        let enc = try SecretBox.encrypt(pt)
        #expect(enc.hasPrefix(SecretBox.prefix))
        let back = try SecretBox.decryptIfPresent(enc)
        #expect(back == pt)
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

    @Test("isEncrypted identifies only enc:v1: payloads")
    func is_encrypted_prefix_check() {
        #expect(SecretBox.isEncrypted("enc:v1:AAA"))
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
