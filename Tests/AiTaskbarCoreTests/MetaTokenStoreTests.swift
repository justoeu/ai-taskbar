import Testing
import Foundation
@testable import AiTaskbarCore

/// The app's sealed copy of the Muse token: what keeps a Muse self-update
/// (which drops every Keychain grant) from costing the user a password.
@Suite("Meta token store")
struct MetaTokenStoreTests {
    static let thisMac = "11111111-2222-3333-4444-555555555555"
    static let otherMac = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("save then load round-trips, sealed enc:v2 at 0600, never plaintext")
    func round_trip_sealed() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetaTokenStore(fileURL: dir.appendingPathComponent("meta-token"), machineID: Self.thisMac)
        try store.save("dca:secret-token")
        #expect(store.load() == "dca:secret-token")
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        expectTrue(raw.hasPrefix(SecretBox.prefixV2))
        expectFalse(raw.contains("secret-token"))
        let perms = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test("a copy sealed on another Mac reads as absent")
    func other_mac_is_absent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("meta-token")
        try MetaTokenStore(fileURL: url, machineID: Self.otherMac).save("dca:x")
        #expect(MetaTokenStore(fileURL: url, machineID: Self.thisMac).load() == nil)
    }

    @Test("non-dca values are never stored; clear removes the copy")
    func rejects_non_dca_and_clears() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetaTokenStore(fileURL: dir.appendingPathComponent("meta-token"), machineID: Self.thisMac)
        try store.save("LLM|not-a-login")
        expectFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        try store.save("dca:y")
        store.clear()
        #expect(store.load() == nil)
    }

    @Test("a symlinked token file is ignored")
    func symlink_ignored() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = MetaTokenStore(fileURL: dir.appendingPathComponent("real"), machineID: Self.thisMac)
        try real.save("dca:z")
        let link = dir.appendingPathComponent("meta-token")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.fileURL)
        #expect(MetaTokenStore(fileURL: link, machineID: Self.thisMac).load() == nil)
    }

    @Test("without a hardware UUID nothing is stored (no machine-independent copy)")
    func no_machine_id_no_copy() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetaTokenStore(fileURL: dir.appendingPathComponent("meta-token"), machineID: nil)
        try store.save("dca:x")
        expectFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("an unchanged token is not rewritten")
    func unchanged_not_rewritten() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetaTokenStore(fileURL: dir.appendingPathComponent("meta-token"), machineID: Self.thisMac)
        try store.save("dca:same")
        let first = try Data(contentsOf: store.fileURL)
        try store.save("dca:same")
        #expect(try Data(contentsOf: store.fileURL) == first)  // AES-GCM nonces differ: a rewrite would change bytes
    }

    @Test("a tampered copy reads as absent")
    func tampered_is_absent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetaTokenStore(fileURL: dir.appendingPathComponent("meta-token"), machineID: Self.thisMac)
        try store.save("dca:t")
        var bytes = Array(try Data(contentsOf: store.fileURL))
        bytes[bytes.count - 3] ^= 0x01
        try Data(bytes).write(to: store.fileURL)
        #expect(store.load() == nil)
    }

    @Test("clear reports success for a missing file")
    func clear_missing_is_success() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetaTokenStore(fileURL: dir.appendingPathComponent("meta-token"), machineID: Self.thisMac)
        expectTrue(store.clear())
    }
}
