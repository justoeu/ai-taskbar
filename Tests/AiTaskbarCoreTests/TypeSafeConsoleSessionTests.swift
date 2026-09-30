import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("TypeSafe console session")
struct TypeSafeConsoleSessionTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("capture keeps only the three login cookies, in a fixed order")
    func capture_filters() throws {
        let s = try #require(TypeSafeConsoleSession.capture([
            (name: "cf_clearance", value: "CF", expiresAt: nil),
            (name: "organization_id", value: "org_1", expiresAt: t0.addingTimeInterval(300)),
            (name: "__cf_bm", value: "BM", expiresAt: nil),
            (name: "session_id", value: "sid", expiresAt: t0.addingTimeInterval(100)),
            (name: "session", value: "tok", expiresAt: nil),
            (name: "_ga", value: "GA", expiresAt: nil),
        ]))
        #expect(s.cookieHeader == "session=tok; session_id=sid; organization_id=org_1")
        // The earliest expiry wins; a cookie without one does not shorten it.
        expectTrue(s.expiresAt == t0.addingTimeInterval(100))
    }

    @Test("capture needs all three cookies, non-empty and header-safe")
    func capture_requires_all() {
        let full: [(name: String, value: String, expiresAt: Date?)] = [
            (name: "session", value: "a", expiresAt: nil),
            (name: "session_id", value: "b", expiresAt: nil),
            (name: "organization_id", value: "c", expiresAt: nil),
        ]
        expectTrue(TypeSafeConsoleSession.capture(full) != nil)
        expectTrue(TypeSafeConsoleSession.capture(Array(full.prefix(2))) == nil)
        for bad in ["", "x; y=1", "x\r\nHost: evil", "a,b", "a b"] {
            var cookies = full
            cookies[0] = (name: "session", value: bad, expiresAt: nil)
            expectTrue(TypeSafeConsoleSession.capture(cookies) == nil)
        }
    }

    @Test("expiry and the two-day warning")
    func expiry() {
        let s = TypeSafeConsoleSession(cookieHeader: "h", expiresAt: t0)
        #expect(s.isExpired(now: t0))
        #expect(!s.isExpired(now: t0.addingTimeInterval(-1)))
        #expect(s.isExpiringSoon(now: t0.addingTimeInterval(-3600)))
        #expect(!s.isExpiringSoon(now: t0.addingTimeInterval(-3 * 86_400)))
        #expect(!s.isExpiringSoon(now: t0))
        let noExpiry = TypeSafeConsoleSession(cookieHeader: "h", expiresAt: nil)
        #expect(!noExpiry.isExpired(now: t0))
        #expect(!noExpiry.isExpiringSoon(now: t0))
    }

    @Test("built from config only when a session is saved")
    func from_config() throws {
        expectTrue(TypeSafeConsoleSession(config: TypeSafeConfig()) == nil)
        expectTrue(TypeSafeConsoleSession(config: TypeSafeConfig(consoleSession: "")) == nil)
        let s = try #require(TypeSafeConsoleSession(config: TypeSafeConfig(consoleSession: "session=a",
                                                                           consoleSessionExpiresAt: 1_790_000_000)))
        #expect(s.cookieHeader == "session=a")
        expectTrue(s.expiresAt == t0)
    }

    @Test("the store hands out whatever was set last")
    func store() {
        let store = TypeSafeSessionStore()
        expectTrue(store.current == nil)
        let s = TypeSafeConsoleSession(cookieHeader: "h", expiresAt: nil)
        store.set(s)
        expectTrue(store.current == s)
        store.set(nil)
        expectTrue(store.current == nil)
    }

    @Test("config: console fields decode, an int expiry included, and default to nil")
    func config_decode() throws {
        let c = try JSONDecoder().decode(TypeSafeConfig.self, from: Data(
            #"{"console_session":"session=a","console_session_expires_at":1790000000}"#.utf8))
        #expect(c.consoleSession == "session=a")
        expectTrue(c.consoleSessionExpiresAt == 1_790_000_000)
        let empty = try JSONDecoder().decode(TypeSafeConfig.self, from: Data(#"{"console_session":""}"#.utf8))
        expectTrue(empty.consoleSession == nil)
        expectTrue(empty.consoleSessionExpiresAt == nil)
    }

    @Test("the session is encrypted on disk, decrypted on load, and cleared on sign-out")
    func persisted_encrypted() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-typesafe-session-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent("config.toml")
        let loader = ConfigLoader(path: path)
        _ = try loader.load()
        try loader.applyChanges([
            .secret(section: "typesafe", key: "console_session", plaintext: "session=SECRET-MARKER; session_id=b"),
            .double(section: "typesafe", key: "console_session_expires_at", value: 1_790_000_000),
        ])
        let onDisk = try String(contentsOf: path, encoding: .utf8)
        #expect(!onDisk.contains("SECRET-MARKER"))
        let perms = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let loaded = try loader.load()
        #expect(loaded.typesafe.consoleSession == "session=SECRET-MARKER; session_id=b")
        expectTrue(loaded.typesafe.consoleSessionExpiresAt == 1_790_000_000)

        try loader.applyChanges([
            .secret(section: "typesafe", key: "console_session", plaintext: nil),
            .double(section: "typesafe", key: "console_session_expires_at", value: 0),
        ])
        let cleared = try loader.load()
        expectTrue(cleared.typesafe.consoleSession == nil)
        expectTrue(TypeSafeConsoleSession(config: cleared.typesafe) == nil)
    }

    @Test("snapshot: console states round-trip; an older cache reads as not connected")
    func snapshot_states() throws {
        let usage = TypeSafeUsage(todayInputTokens: 1, todayOutputTokens: 2, todayRequests: 3,
                                  weekInputTokens: 4, weekOutputTokens: 5, weekRequests: 6,
                                  hourly: [TypeSafeUsagePoint(start: t0, inputTokens: 1, outputTokens: 2, requests: 3)])
        for state in [TypeSafeConsoleState.notConnected, .connected(expiresAt: t0), .connected(expiresAt: nil),
                      .expired, .unavailable(since: t0)] {
            let s = TypeSafeSnapshot(models: [TypeSafeModel(name: "jev-latest")], usage: usage, console: state)
            let back = try SharedCoders.decoder.decode(TypeSafeSnapshot.self, from: SharedCoders.encoder.encode(s))
            #expect(back == s)
        }
        let old = try SharedCoders.decoder.decode(TypeSafeSnapshot.self, from: Data(#"{"models":[]}"#.utf8))
        #expect(old.console == .notConnected)
        expectTrue(old.usage == nil)
        let odd = try SharedCoders.decoder.decode(TypeSafeSnapshot.self, from: Data(#"{"console":{"weird":{}}}"#.utf8))
        #expect(odd.console == .notConnected)
    }

    @Test("with(...) keeps the models and replaces the console part")
    func with_console() {
        let s = TypeSafeSnapshot(planLabel: "p", models: [TypeSafeModel(name: "a")])
        let c = s.with(billing: TypeSafeBilling(spentUSD: 1, balanceUSD: 2), usage: nil, console: .expired)
        #expect(c.models == s.models)
        #expect(c.planLabel == "p")
        #expect(c.console == .expired)
        expectTrue(c.billing?.balanceUSD == 2)
    }
}
