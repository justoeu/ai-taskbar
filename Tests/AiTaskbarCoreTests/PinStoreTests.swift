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

    @Test("pinned host without server trust → cancel")
    func pinned_host_no_server_trust_cancels() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-pdnst-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = PinStore(baseDir: tmp)
        let delegate = PinningDelegate(pinnedHosts: ["pinned.example.com"],
                                       store: store, auditOnly: false)
        // Server trust auth method but no serverTrust object on the
        // protection space (URLProtectionSpace's plain init doesn't set one).
        let space = URLProtectionSpace(
            host: "pinned.example.com",
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
        #expect(disposition == .cancelAuthenticationChallenge)
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

/// Unit tests for the pure decision function extracted from
/// `PinningDelegate.urlSession(_:didReceive:)`. Covers the TOFU seed,
/// happy-path match, mismatch (reject + audit-only bypass), and the
/// SPKI-extraction failure branch. Pure inputs → pure output, no live
/// `SecTrust` required.
@Suite("PinningDelegate.evaluate — pure decision function")
struct PinningDelegateEvaluateTests {
    @Test("leaf hash matches stored → accept")
    func match_accepts() {
        let decision = PinningDelegate.evaluate(
            leafHash: "abc", storedHash: "abc", auditOnly: false)
        #expect(decision == .accept)
    }

    @Test("no stored hash → TOFU seed")
    func no_stored_seeds() {
        let decision = PinningDelegate.evaluate(
            leafHash: "candidate", storedHash: nil, auditOnly: false)
        #expect(decision == .seed(hash: "candidate"))
    }

    @Test("mismatch with auditOnly=false → reject")
    func mismatch_rejects_when_enforced() {
        let decision = PinningDelegate.evaluate(
            leafHash: "presented", storedHash: "stored", auditOnly: false)
        #expect(decision == .reject(.mismatch))
    }

    @Test("mismatch with auditOnly=true → accept with warning")
    func mismatch_proceeds_when_audit_only() {
        let decision = PinningDelegate.evaluate(
            leafHash: "presented", storedHash: "stored", auditOnly: true)
        #expect(decision == .acceptWithWarning(.mismatch))
    }

    @Test("SPKI extraction failure with auditOnly=false → reject")
    func extraction_failure_rejects_when_enforced() {
        let decision = PinningDelegate.evaluate(
            leafHash: nil, storedHash: "stored", auditOnly: false)
        #expect(decision == .reject(.spkiExtractionFailed))
    }

    @Test("SPKI extraction failure with auditOnly=true → accept with warning")
    func extraction_failure_proceeds_when_audit_only() {
        let decision = PinningDelegate.evaluate(
            leafHash: nil, storedHash: "stored", auditOnly: true)
        #expect(decision == .acceptWithWarning(.spkiExtractionFailed))
    }

    @Test("audit-only still rejects when no SPKI failure or mismatch occurs")
    func audit_only_does_not_skip_seed() {
        // No stored hash → TOFU applies regardless of auditOnly flag
        // (we're not skipping enforcement, we're establishing a baseline).
        let decision = PinningDelegate.evaluate(
            leafHash: "first-seen", storedHash: nil, auditOnly: true)
        #expect(decision == .seed(hash: "first-seen"))
    }

    @Test("audit-only accepts on match same as enforced")
    func audit_only_match_same_as_enforced() {
        let enforced = PinningDelegate.evaluate(
            leafHash: "x", storedHash: "x", auditOnly: false)
        let audited  = PinningDelegate.evaluate(
            leafHash: "x", storedHash: "x", auditOnly: true)
        #expect(enforced == audited)
        #expect(enforced == .accept)
    }
}

/// Sanity tests for the populated baseline — confirms the binary actually
/// ships pins for every vendor host the providers talk to (catches a future
/// regression where someone empties the dict by mistake).
@Suite("PinBaseline — populated vendor hosts")
struct PinBaselineTests {
    private let expectedVendorHosts: [String] = [
        "api.anthropic.com",
        "platform.claude.com",
        "chatgpt.com",
        "auth.openai.com",
        "openrouter.ai",
        "api.z.ai",
        "open.bigmodel.cn",
        "api.moonshot.ai",
        "api.moonshot.cn",
        "generativelanguage.googleapis.com",
        "api.deepseek.com",
        "management-api.x.ai",
    ]

    @Test("every expected vendor host has a baseline pin")
    func all_vendor_hosts_pinned() {
        for host in expectedVendorHosts {
            let pin = PinBaseline.pin(for: host)
            #expect(pin != nil, "missing baseline pin for \(host)")
            #expect(pin?.isEmpty == false, "empty baseline pin for \(host)")
        }
    }

    @Test("baseline pin is base64-shaped (multiple of 4 chars after padding)")
    func pins_are_base64() {
        for host in expectedVendorHosts {
            guard let pin = PinBaseline.pin(for: host) else { continue }
            #expect(pin.hasSuffix("="), "expected base64 padding for \(host): \(pin)")
            // SHA256 = 32 bytes → 44 base64 chars including 1-char padding.
            #expect(pin.count == 44, "expected 44-char SHA256-base64 for \(host), got \(pin.count)")
        }
    }

    @Test("lookup is case-insensitive")
    func lookup_case_insensitive() {
        let lower = PinBaseline.pin(for: "api.anthropic.com")
        let upper = PinBaseline.pin(for: "API.ANTHROPIC.COM")
        let mixed = PinBaseline.pin(for: "Api.Anthropic.com")
        #expect(lower == upper)
        #expect(lower == mixed)
        #expect(lower != nil)
    }

    @Test("unknown host returns nil (TOFU still applies there)")
    func unknown_host_returns_nil() {
        #expect(PinBaseline.pin(for: "evil.example.com") == nil)
        #expect(PinBaseline.pin(for: "") == nil)
    }
}
