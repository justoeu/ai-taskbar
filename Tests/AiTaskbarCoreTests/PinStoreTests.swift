import Testing
import Foundation
@testable import AiTaskbarCore

/// Empty `URLAuthenticationChallengeSender` — required to instantiate
/// `URLAuthenticationChallenge` even though the delegate never calls back
/// through it (we read the synchronous `completionHandler` outcome instead).
private final class NoopSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

@Suite("PinStore — TOFU pin storage")
struct PinStoreTests {
    let tmp: URL

    init() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-pins-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
    }

    @Test("get returns nil when no pin stored")
    func get_nil_when_no_pin() {
        let store = PinStore(baseDir: tmp)
        #expect(store.get(host: "api.example.com") == nil)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("set then get round-trips the hash")
    func set_then_get_round_trip() {
        let store = PinStore(baseDir: tmp)
        store.set(host: "api.example.com",
                  hash: "sha256/abc123==")
        #expect(store.get(host: "api.example.com") == "sha256/abc123==")
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("host lookup is case-insensitive")
    func host_lookup_case_insensitive() {
        let store = PinStore(baseDir: tmp)
        store.set(host: "API.example.com", hash: "h")
        #expect(store.get(host: "api.example.com") == "h")
        #expect(store.get(host: "API.EXAMPLE.COM") == "h")
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("pin file is locked to 0o600")
    func pin_file_is_locked_to_0o600() throws {
        let store = PinStore(baseDir: tmp)
        store.set(host: "api.example.com", hash: "h")
        let file = tmp.appendingPathComponent("api.example.com.txt")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("clear removes the pin from disk + cache")
    func clear_removes_pin() {
        let store = PinStore(baseDir: tmp)
        store.set(host: "api.example.com", hash: "h")
        store.clear(host: "api.example.com")
        #expect(store.get(host: "api.example.com") == nil)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("set is durable — fresh instance reads same hash from disk")
    func set_durable_across_instances() {
        let a = PinStore(baseDir: tmp)
        a.set(host: "api.example.com", hash: "stored")
        let b = PinStore(baseDir: tmp)
        #expect(b.get(host: "api.example.com") == "stored")
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("whitespace in file is trimmed")
    func whitespace_in_file_is_trimmed() throws {
        let store = PinStore(baseDir: tmp)
        let file = tmp.appendingPathComponent("api.example.com.txt")
        try "  trimmedhash  \n\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(store.get(host: "api.example.com") == "trimmedhash")
        try? FileManager.default.removeItem(at: tmp)
    }
}

@Suite("PinningDelegate construction")
struct PinningDelegateTests {
    @Test("lowercases pinned hosts")
    func lowercases_pinned_hosts() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-pd-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        let store = PinStore(baseDir: tmp)
        let pd = PinningDelegate(
            pinnedHosts: ["API.example.com", "Mixed.Case.com"],
            store: store, auditOnly: false)
        #expect(pd.pinnedHosts.contains("api.example.com"))
        #expect(pd.pinnedHosts.contains("mixed.case.com"))
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("non-server-trust auth method falls through to performDefaultHandling")
    func non_server_trust_falls_through() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-pdnt-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = PinStore(baseDir: tmp)
        let delegate = PinningDelegate(pinnedHosts: ["api.example.com"],
                                       store: store, auditOnly: false)
        let space = URLProtectionSpace(
            host: "api.example.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: NoopSender())
        var disposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(URLSession.shared,
                            didReceive: challenge) { d, _ in disposition = d }
        #expect(disposition == .performDefaultHandling)
    }

    @Test("server-trust on non-pinned host falls through")
    func server_trust_non_pinned_host_falls_through() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-pdnph-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = PinStore(baseDir: tmp)
        let delegate = PinningDelegate(pinnedHosts: ["pinned.example.com"],
                                       store: store, auditOnly: false)
        let space = URLProtectionSpace(
            host: "unpinned.example.com",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust)
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: NoopSender())
        var disposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(URLSession.shared,
                            didReceive: challenge) { d, _ in disposition = d }
        #expect(disposition == .performDefaultHandling)
    }

    @Test("auditOnly flag preserves state")
    func auditOnly_flag_preserved() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-pd2-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        let store = PinStore(baseDir: tmp)
        let pd = PinningDelegate(pinnedHosts: ["a"], store: store, auditOnly: true)
        #expect(pd.auditOnly)
        let pd2 = PinningDelegate(pinnedHosts: ["a"], store: store, auditOnly: false)
        #expect(!pd2.auditOnly)
        try? FileManager.default.removeItem(at: tmp)
    }
}
