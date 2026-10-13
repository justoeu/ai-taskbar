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
}
