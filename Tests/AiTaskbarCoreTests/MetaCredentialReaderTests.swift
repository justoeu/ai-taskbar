import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("MetaCredentialReader (SDD-meta-muse §7)")
struct MetaCredentialReaderTests {
    private func reader(authJSON: String?,
                        keychain: @escaping @Sendable () -> MetaKeychainRead) throws -> MetaCredentialReader {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let auth = dir.appendingPathComponent("auth.json")
        if let authJSON {
            try authJSON.write(to: auth, atomically: true, encoding: .utf8)
        }
        return MetaCredentialReader(authFileURL: auth, keychainRead: keychain)
    }

    @Test("inline dca token in auth.json wins over Keychain")
    func inline_wins() throws {
        let r = try reader(authJSON: #"{"providers":{"meta":{"access_token":"dca:inline"}}}"#,
                           keychain: { .found(Data(#"{"access_token":"dca:keychain"}"#.utf8)) })
        #expect(r.resolve() == .token("dca:inline"))
        expectTrue(r.hasLogin())
    }

    @Test("mechanism oauth without inline token reads the Keychain")
    func oauth_mechanism_uses_keychain() throws {
        let r = try reader(authJSON: #"{"providers":{"meta":{"mechanism":"oauth"}}}"#,
                           keychain: { .found(Data(#"{"access_token":"dca:keychain"}"#.utf8)) })
        #expect(r.resolve() == .token("dca:keychain"))
    }

    @Test("non-dca inline token is ignored, Keychain is tried")
    func non_dca_ignored() throws {
        let r = try reader(authJSON: #"{"providers":{"meta":{"access_token":"LLM_dashboard"}}}"#,
                           keychain: { .found(Data(#"{"access_token":"dca:keychain2"}"#.utf8)) })
        #expect(r.resolve() == .token("dca:keychain2"))
    }

    @Test("uncontracted keychain payload shapes are refused")
    func uncontracted_payload_refused() throws {
        for payload in [#"{"accessToken":"dca:camel"}"#, #"{"token":"dca:bare"}"#, "dca:rawstring"] {
            let r = try reader(authJSON: nil, keychain: { .found(Data(payload.utf8)) })
            guard case .unavailable = r.resolve() else {
                Issue.record("payload \(payload) must not resolve to a token")
                continue
            }
        }
    }

    @Test("detection classifies detected, blocked and missing without a token")
    func detection_states() throws {
        let found = try reader(authJSON: nil,
                               keychain: { .found(Data(#"{"access_token":"dca:x"}"#.utf8)) })
        #expect(found.detection() == .detected)
        let blocked = try reader(authJSON: nil, keychain: { .blocked })
        #expect(blocked.detection() == .keychainBlocked)
        let missing = try reader(authJSON: nil, keychain: { .missing })
        #expect(missing.detection() == .missing)
    }

    @Test("oauth marker alone does not fake detection; the probe decides")
    func oauth_marker_falls_through_to_probe() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let auth = dir.appendingPathComponent("auth.json")
        try #"{"providers":{"meta":{"mechanism":"oauth"}}}"#
            .write(to: auth, atomically: true, encoding: .utf8)
        let blocked = MetaCredentialReader(authFileURL: auth,
                                           keychainRead: { .missing },
                                           keychainProbe: { .blocked })
        #expect(blocked.detection() == .keychainBlocked)
        let missing = MetaCredentialReader(authFileURL: auth,
                                           keychainRead: { .missing },
                                           keychainProbe: { .missing })
        #expect(missing.detection() == .missing)
    }

    @Test("detection prefers the attribute probe and never reads the secret")
    func detection_uses_probe_not_read() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // If detection() consulted the data read it would see a token and
        // answer .detected; the probe says blocked and must win (P-9).
        let r = MetaCredentialReader(
            authFileURL: dir.appendingPathComponent("auth.json"),
            keychainRead: { .found(Data(#"{"access_token":"dca:must-not-be-read"}"#.utf8)) },
            keychainProbe: { .blocked })
        #expect(r.detection() == .keychainBlocked)
        expectTrue(r.hasLogin())
        // resolve() is the only path allowed to read the payload.
        #expect(r.resolve() == .token("dca:must-not-be-read"))
    }

    @Test("no auth file and blocked Keychain degrades, never prompts")
    func blocked_degrades() throws {
        let r = try reader(authJSON: nil, keychain: { .blocked })
        #expect(r.resolve() == .keychainBlocked)
    }

    @Test("nothing anywhere is a plain missing login")
    func missing_login() throws {
        let r = try reader(authJSON: nil, keychain: { .missing })
        #expect(r.resolve() == .missing)
        expectFalse(r.hasLogin())
    }

    @Test("hasLogin sees an oauth auth file without reading any secret")
    func has_login_from_file() throws {
        let r = try reader(authJSON: #"{"providers":{"meta":{"mechanism":"oauth"}}}"#,
                           keychain: { .missing })
        expectTrue(r.hasLogin())
    }

    @Test("ACL-blocked direct read reports blocked; no security-tool fallback")
    func blocked_has_no_tool_fallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = MetaCredentialReader(
            authFileURL: dir.appendingPathComponent("auth.json"),
            keychainRead: { .blocked })
        #expect(r.resolve() == .keychainBlocked)
    }

    @Test("the Meta reader never shells out to /usr/bin/security")
    func source_has_no_security_tool() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AiTaskbarCore/Credentials/MetaCredentialReader.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        // Code lines only: the explanatory comment names the tool on purpose.
        let code = text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("SecurityToolCredentialReader"))
        #expect(!code.contains("/usr/bin/security"))
        #expect(!code.contains("Process("))
    }

    @Test("auth file URL resolution: config, env, default")
    func auth_url_resolution() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(MetaCredentialReader.authFileURL(configPath: "/c/auth.json",
                                                 environment: ["MUSE_AUTH_PATH": "/e/auth.json"],
                                                 home: home).path == "/c/auth.json")
        #expect(MetaCredentialReader.authFileURL(configPath: nil,
                                                 environment: ["MUSE_AUTH_PATH": "/e/auth.json"],
                                                 home: home).path == "/e/auth.json")
        #expect(MetaCredentialReader.authFileURL(configPath: nil, environment: [:],
                                                 home: home).path == "/Users/test/.config/muse/auth.json")
        #expect(MetaCredentialReader.keychainService == "ai.meta.dev.credentials")
        #expect(MetaCredentialReader.keychainAccount == "meta")
    }

    // MARK: stored copy (MetaTokenStore)

    private func storeReader(keychain: @escaping @Sendable () -> MetaKeychainRead,
                             probe: (@Sendable () -> MetaKeychainProbe)? = nil)
        throws -> (MetaCredentialReader, MetaTokenStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meta-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MetaTokenStore(fileURL: dir.appendingPathComponent("meta-token"),
                                   machineID: "11111111-2222-3333-4444-555555555555")
        let reader = MetaCredentialReader(authFileURL: dir.appendingPathComponent("auth.json"),
                                          keychainRead: keychain, keychainProbe: probe,
                                          tokenStore: store)
        return (reader, store, dir)
    }

    @Test("a successful Keychain read keeps a sealed copy of the token")
    func found_saves_copy() throws {
        let payload = Data(#"{"access_token":"dca:from-keychain"}"#.utf8)
        let (r, store, dir) = try storeReader(keychain: { .found(payload) })
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(r.resolve() == .token("dca:from-keychain"))
        #expect(store.load() == "dca:from-keychain")
    }

    @Test("after Muse drops the grant, the stored copy answers without a banner")
    func blocked_uses_copy() throws {
        let (r, store, dir) = try storeReader(keychain: { .blocked }, probe: { .blocked })
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(r.resolve() == .keychainBlocked)
        #expect(r.detection() == .keychainBlocked)
        try store.save("dca:kept")
        #expect(r.resolve() == .token("dca:kept"))
        #expect(r.detection() == .detected)
    }

    @Test("muse logout (item gone) clears the copy")
    func missing_clears_copy() throws {
        let (r, store, dir) = try storeReader(keychain: { .missing })
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save("dca:old")
        #expect(r.resolve() == .missing)
        #expect(store.load() == nil)
    }

    @Test("discardStoredToken drops only the matching copy")
    func discard_matching_only() throws {
        let (r, store, dir) = try storeReader(keychain: { .blocked })
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save("dca:current")
        expectFalse(r.discardStoredToken("dca:other"))
        #expect(store.load() == "dca:current")
        expectTrue(r.discardStoredToken("dca:current"))
        #expect(store.load() == nil)
        #expect(r.resolve() == .keychainBlocked)
    }
}
