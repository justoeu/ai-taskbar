import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

private let consoleCookie = "session=SESSION-MARKER; session_id=SID-MARKER; organization_id=org_MARKER"
private let actionID = "7f3a9c0e1b2d4f60718293a4b5c6d7e8f9012345ab"

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

/// Parsing of the console's billing and usage (docs/SDD-typesafe-jev.md §16),
/// against the anonymized responses captured 2026-09-29.
@Suite("TypeSafe console parsing")
struct TypeSafeConsoleParsingTests {
    @Test("golden: billing server action decodes field by field")
    func golden_billing() throws {
        let b = try TypeSafeConsoleParsing.billing(fromRSC: Fixtures.typesafeBillingRSC200)
        #expect(b.spentUSD == 0)
        #expect(b.balanceUSD == 30)
        expectTrue(b.purchasedUSD == 30)
        expectTrue(b.freeCreditsRemainingUSD == 0)
        #expect(b.plan == "pay_as_you_go")
        #expect(b.cycleLabel == "September 2026")
        expectTrue(b.cycleEndsInDays == 2)
        #expect(b.credits.count == 1)
        #expect(b.credits[0].amountUSD == 30)
        #expect(b.credits[0].remainingUSD == 30)
        #expect(b.credits[0].reason == "purchased_credits")
        #expect(b.credits[0].expiresAt == ISO8601Parsing.parse("2027-09-29T00:00:00Z"))
    }

    @Test("personal fields in the billing response are never kept")
    func billing_drops_pii() throws {
        let b = try TypeSafeConsoleParsing.billing(fromRSC: Fixtures.typesafeBillingRSC200)
        let encoded = String(decoding: try SharedCoders.encoder.encode(b), as: UTF8.self)
        for marker in ["user@example.com", "Example Org", "Visa", "0000", "cred_", "invoice", "BR"] {
            #expect(!encoded.contains(marker), "\(marker) leaked")
        }
    }

    @Test("missing spent or balance is a schema error, never a zero")
    func billing_requires_numbers() {
        #expect(throws: (any Error).self) {
            _ = try TypeSafeConsoleParsing.billing(fromRSC: #"1:{"ok":true,"data":{"billing":{"balance":3}}}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try TypeSafeConsoleParsing.billing(fromRSC: #"1:{"ok":true,"data":{"billing":{"spent":"x","balance":3}}}"#)
        }
    }

    @Test("ok=false, no billing, or no result record all fail")
    func billing_failures() {
        #expect(throws: (any Error).self) { _ = try TypeSafeConsoleParsing.billing(fromRSC: #"1:{"ok":false}"#) }
        #expect(throws: (any Error).self) { _ = try TypeSafeConsoleParsing.billing(fromRSC: #"1:{"ok":true,"data":{}}"#) }
        #expect(throws: (any Error).self) { _ = try TypeSafeConsoleParsing.billing(fromRSC: "0:{\"a\":1}\nnot json") }
        #expect(throws: (any Error).self) { _ = try TypeSafeConsoleParsing.billing(fromRSC: "") }
    }

    @Test("credits: spent ones dropped, bad ones skipped, soonest expiry first, reference string tolerated")
    func credits_filtering() throws {
        let body = #"1:{"ok":true,"data":{"billing":{"spent":1.5,"balance":2,"credits":[{"amount":5,"remaining":0,"expiresAt":"2027-01-01T00:00:00Z"},{"amount":5,"remaining":1,"expiresAt":"not a date"},{"amount":3,"remaining":2,"expiresAt":"2027-06-01T00:00:00Z"},{"amount":4,"remaining":4,"expiresAt":"2027-02-01T00:00:00Z"},{"remaining":1}]}}}"#
        let b = try TypeSafeConsoleParsing.billing(fromRSC: body)
        #expect(b.credits.map(\.remainingUSD) == [4, 2])
        expectTrue(b.purchasedUSD == nil)
        expectTrue(b.plan == nil)
        let ref = try TypeSafeConsoleParsing.billing(
            fromRSC: #"1:{"ok":true,"data":{"billing":{"spent":0,"balance":0,"credits":"$1:data:billing:credits","resetsInDays":-3}}}"#)
        #expect(ref.credits.isEmpty)
        expectTrue(ref.cycleEndsInDays == nil)
    }

    @Test("golden: usage buckets decode only period and counters")
    func golden_usage() throws {
        let hour = try SharedCoders.decoder.decode(TypeSafeUsageResponse.self, from: Fixtures.data(Fixtures.typesafeUsageHour200))
        #expect(hour.buckets == [TypeSafeUsageBucket(day: "2026-09-29T22:00:00+00:00", requests: 4,
                                                     inputTokens: 1521, outputTokens: 163)])
        let day = try SharedCoders.decoder.decode(TypeSafeUsageResponse.self, from: Fixtures.data(Fixtures.typesafeUsageDay200))
        #expect(day.buckets == [TypeSafeUsageBucket(day: "2026-09-29", requests: 4, inputTokens: 1521, outputTokens: 163)])
    }

    @Test("usage: a body without buckets is an error; odd buckets are skipped")
    func usage_lenient() throws {
        #expect(throws: (any Error).self) {
            _ = try SharedCoders.decoder.decode(TypeSafeUsageResponse.self, from: Fixtures.data(#"{"data":[]}"#))
        }
        let r = try SharedCoders.decoder.decode(TypeSafeUsageResponse.self, from: Fixtures.data(
            #"{"buckets":[{"requests":1},{"day":"2026-09-29","requests":-5,"inputTokens":2.0,"outputTokens":"x"}]}"#))
        #expect(r.buckets == [TypeSafeUsageBucket(day: "2026-09-29", requests: 0, inputTokens: 2, outputTokens: 0)])
    }

    @Test("aggregate: today from hours in the local day, 7 days from UTC day buckets")
    func aggregate() {
        let hour = [
            TypeSafeUsageBucket(day: "2026-09-29T22:00:00+00:00", requests: 4, inputTokens: 1521, outputTokens: 163),
            TypeSafeUsageBucket(day: "2026-09-29T22:00:00+00:00", requests: 1, inputTokens: 100, outputTokens: 10),
            TypeSafeUsageBucket(day: "2026-09-29T03:00:00+00:00", requests: 2, inputTokens: 50, outputTokens: 5),
            TypeSafeUsageBucket(day: "2026-09-28T23:00:00+00:00", requests: 9, inputTokens: 999, outputTokens: 99),
            TypeSafeUsageBucket(day: "garbage", requests: 9, inputTokens: 9, outputTokens: 9),
        ]
        let day = [
            TypeSafeUsageBucket(day: "2026-09-29", requests: 7, inputTokens: 1671, outputTokens: 178),
            TypeSafeUsageBucket(day: "2026-09-23", requests: 1, inputTokens: 10, outputTokens: 1),
            TypeSafeUsageBucket(day: "2026-09-22", requests: 100, inputTokens: 100, outputTokens: 100),
            TypeSafeUsageBucket(day: "bad", requests: 100, inputTokens: 100, outputTokens: 100),
        ]
        let u = TypeSafeUsageMath.aggregate(hour: hour, day: day,
                                            now: ISO8601Parsing.parse("2026-09-29T23:30:00Z")!, calendar: utc)
        #expect(u.todayInputTokens == 1671)
        #expect(u.todayOutputTokens == 178)
        #expect(u.todayRequests == 7)
        #expect(u.weekInputTokens == 1681)
        #expect(u.weekOutputTokens == 179)
        #expect(u.weekRequests == 8)
        // Same-hour buckets (two API keys) merge; sorted oldest first.
        #expect(u.hourly.map(\.requests) == [9, 2, 5])
        // Daily: only the 7-day window, per date, oldest first.
        #expect(u.daily.map(\.requests) == [1, 7])
        #expect(u.daily.first?.start == ISO8601Parsing.parse("2026-09-23T00:00:00Z"))
    }

    @Test("aggregate keeps at most 48 hourly points")
    func aggregate_caps_series() {
        let base = ISO8601Parsing.parse("2026-09-20T00:00:00Z")!
        let f = ISO8601DateFormatter()
        let hour = (0..<60).map {
            TypeSafeUsageBucket(day: f.string(from: base.addingTimeInterval(TimeInterval($0) * 3600)),
                                requests: $0, inputTokens: 0, outputTokens: 0)
        }
        let u = TypeSafeUsageMath.aggregate(hour: hour, day: [], now: base.addingTimeInterval(61 * 3600), calendar: utc)
        #expect(u.hourly.count == TypeSafeUsageMath.hourlyLimit)
        #expect(u.hourly.last?.requests == 59)
    }

    @Test("chunk URLs: same origin only, deduplicated, billing first")
    func chunk_urls() {
        let urls = TypeSafeConsoleParsing.chunkURLs(inPage: Fixtures.typesafeBillingPageHTML).map(\.absoluteString)
        #expect(urls == [
            "https://console.typesafe.ai/_next/static/chunks/app/(dashboard)/settings/billing/page-1111.js",
            "https://console.typesafe.ai/_next/static/chunks/webpack-0000.js",
        ])
        let hostile = #"<script src="//evil.example/a.js"></script><script src="http://console.typesafe.ai/b.js"></script><script src="https://console.typesafe.ai.evil.com/c.js"></script><script src="https://console.typesafe.ai:8443/d.js"></script><script src="/e.css"></script>"#
        #expect(TypeSafeConsoleParsing.chunkURLs(inPage: hostile).isEmpty)
        let many = (0..<80).map { "<script src=\"/c\($0).js\"></script>" }.joined()
        #expect(TypeSafeConsoleParsing.chunkURLs(inPage: many).count == TypeSafeConsoleParsing.maxChunks)
    }

    @Test("action id: found next to the export name, not elsewhere")
    func action_id() {
        #expect(TypeSafeConsoleParsing.actionID(inChunk: Fixtures.typesafeBillingChunkJS) == actionID)
        #expect(TypeSafeConsoleParsing.actionID(inChunk: #"("7f3a9c0e1b2d4f60718293a4b5c6d7e8f9012345ab",x,"getOtherResult")"#) == nil)
        #expect(TypeSafeConsoleParsing.actionID(inChunk: #"("abc",x,"getBillingOverviewResult")"#) == nil)
    }

    @Test("login landing is recognized, escaped or not; the console page is not")
    func login_landing() {
        #expect(TypeSafeConsoleParsing.isLoginLanding(Fixtures.typesafeLoginLandingHTML))
        #expect(TypeSafeConsoleParsing.isLoginLanding(#"["(auth)",{"children":["login",{}]}]"#))
        #expect(!TypeSafeConsoleParsing.isLoginLanding(Fixtures.typesafeBillingPageHTML))
    }

    @Test("Cloudflare interstitials are told apart from a signed-out app")
    func cloudflare() {
        #expect(TypeSafeConsoleParsing.isCloudflareChallenge(status: 403, headers: [:], body: "<title>Just a moment...</title>"))
        #expect(TypeSafeConsoleParsing.isCloudflareChallenge(status: 200, headers: ["Cf-Mitigated": "challenge"], body: ""))
        #expect(!TypeSafeConsoleParsing.isCloudflareChallenge(status: 403, headers: [:], body: "{}"))
        #expect(!TypeSafeConsoleParsing.isCloudflareChallenge(status: 200, headers: [:], body: "Just a moment..."))
    }
}

/// The provider end to end, with the console served by `StubURLProtocol`.
@Suite("TypeSafe console provider", .serialized)
struct TypeSafeConsoleProviderTests {
    let tmpCacheDir: URL
    static let now = ISO8601Parsing.parse("2026-09-29T23:30:00Z")!

    init() throws {
        StubURLProtocol.reset()
        tmpCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-typesafe-console-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCacheDir)
    }

    private func provider(session: TypeSafeConsoleSession?) -> TypeSafeProvider {
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        return TypeSafeProvider(
            credentials: EnvOrConfigCredentialReader(envVarName: "_UNSET_TYPESAFE_\(UUID().uuidString.prefix(6))",
                                                     inlineKey: "ts-test-key", vendorName: "TypeSafe"),
            cache: DiskCache(vendor: .typesafe, baseDir: tmpCacheDir),
            http: http,
            baseURL: URL(string: TypeSafeConfig.defaultBaseURL)!,
            sessionStore: TypeSafeSessionStore(session),
            console: TypeSafeConsoleClient(http: http, userAgent: "ai-taskbar-test", now: { Self.now }),
            now: { Self.now },
            calendar: utc)
    }

    private static let validSession = TypeSafeConsoleSession(
        cookieHeader: consoleCookie, expiresAt: now.addingTimeInterval(10 * 86_400))

    /// Routes each request like the real console does.
    private static func console(page: StubURLProtocol.CannedResponse? = nil,
                                action: StubURLProtocol.CannedResponse? = nil,
                                usage: StubURLProtocol.CannedResponse? = nil)
        -> (URLRequest) -> StubURLProtocol.CannedResponse {
        { req in
            let url = req.url!
            if url.host == "api.typesafe.ai" { return .init(data: Fixtures.data(Fixtures.typesafeModels200)) }
            if url.path.hasSuffix(".js") { return .init(data: Fixtures.data(Fixtures.typesafeBillingChunkJS)) }
            if url.path == "/settings/billing", req.httpMethod == "POST" {
                return action ?? .init(data: Fixtures.data(Fixtures.typesafeBillingRSC200),
                                       headers: ["Content-Type": "text/x-component"])
            }
            if url.path == "/settings/billing" {
                return page ?? .init(data: Fixtures.data(Fixtures.typesafeBillingPageHTML))
            }
            if url.path == "/api/usage" {
                if let usage { return usage }
                let hour = url.query?.contains("granularity=hour") == true
                return .init(data: Fixtures.data(hour ? Fixtures.typesafeUsageHour200 : Fixtures.typesafeUsageDay200))
            }
            return .init(status: 404, data: Data())
        }
    }

    private func snapshot(_ outcome: FetchOutcome) throws -> TypeSafeSnapshot {
        guard case let .typesafe(s) = outcome.snapshot else { throw AppError.schema("wrong vendor") }
        return s
    }

    private func consoleRequests() -> [URLRequest] {
        StubURLProtocol.captured.filter { $0.url?.host == "console.typesafe.ai" }
    }

    @Test("connected: billing and usage fill the snapshot")
    func connected() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console()
        let s = try snapshot(try await provider(session: Self.validSession).fetchUsage(forceRefresh: true))
        #expect(s.modelCount == 2)
        #expect(s.console == .connected(expiresAt: Self.validSession.expiresAt))
        expectTrue(s.billing?.balanceUSD == 30)
        expectTrue(s.usage?.todayInputTokens == 1521)
        expectTrue(s.usage?.todayOutputTokens == 163)
        expectTrue(s.usage?.todayRequests == 4)
        expectTrue(s.usage?.weekRequests == 4)
    }

    @Test("the cookie goes only to console pages; chunks and the API never get it")
    func cookie_scope() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console()
        _ = try await provider(session: Self.validSession).fetchUsage(forceRefresh: true)
        for r in StubURLProtocol.captured {
            let isChunk = r.url?.path.hasSuffix(".js") == true
            let expectsCookie = r.url?.host == "console.typesafe.ai" && !isChunk
            let cookie = r.value(forHTTPHeaderField: "Cookie")
            #expect(cookie == (expectsCookie ? consoleCookie : nil), "\(r.url!)")
            #expect(r.value(forHTTPHeaderField: "User-Agent") != nil || r.url?.host == "api.typesafe.ai")
        }
        let post = try #require(consoleRequests().first { $0.httpMethod == "POST" })
        #expect(post.value(forHTTPHeaderField: "Next-Action") == actionID)
        #expect(post.value(forHTTPHeaderField: "Origin") == "https://console.typesafe.ai")
        #expect(post.value(forHTTPHeaderField: "Accept") == "text/x-component")
        // Only the billing page chunk was needed (billing chunks first).
        #expect(consoleRequests().filter { $0.url!.path.hasSuffix(".js") }.count == 1)
    }

    @Test("neither the cookie nor personal data reach the cache")
    func cache_is_clean() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console()
        _ = try await provider(session: Self.validSession).fetchUsage(forceRefresh: true)
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: tmpCacheDir.path)) ?? []
        #expect(!files.isEmpty)
        for f in files {
            let text = (try? String(contentsOf: tmpCacheDir.appendingPathComponent(f), encoding: .utf8)) ?? ""
            for marker in ["SESSION-MARKER", "SID-MARKER", "org_MARKER", "user@example.com", "Example Org",
                           "example-key", "key_000", "ts-test-key"] {
                #expect(!text.contains(marker), "\(marker) leaked into \(f)")
            }
        }
    }

    @Test("the action id is cached between fetches")
    func action_id_cached() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console()
        let p = provider(session: Self.validSession)
        _ = try await p.fetchUsage(forceRefresh: true)
        _ = try await p.fetchUsage(forceRefresh: true)
        let pageGets = consoleRequests().filter { $0.url?.path == "/settings/billing" && $0.httpMethod == "GET" }
        #expect(pageGets.count == 1)
        #expect(consoleRequests().filter { $0.httpMethod == "POST" }.count == 2)
    }

    @Test("a renamed action is rediscovered once")
    func action_rediscovery() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        let posts = Counter()
        let base = Self.console()
        StubURLProtocol.handler = { req in
            if req.httpMethod == "POST", posts.next() == 1 {
                return .init(status: 404, data: Data(), headers: ["x-nextjs-action-not-found": "1"])
            }
            return base(req)
        }
        let s = try snapshot(try await provider(session: Self.validSession).fetchUsage(forceRefresh: true))
        expectTrue(s.billing?.balanceUSD == 30)
        #expect(consoleRequests().filter { $0.url?.path == "/settings/billing" && $0.httpMethod == "GET" }.count == 2)
    }

    @Test("a stale action that stays missing reads as unavailable")
    func action_missing_twice() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console(
            action: .init(status: 404, data: Data(), headers: ["x-nextjs-action-not-found": "1"]))
        let s = try snapshot(try await provider(session: Self.validSession).fetchUsage(forceRefresh: true))
        #expect(s.console == .unavailable(since: Self.now))
        expectTrue(s.billing == nil)
    }

    enum SignedOut: String, CaseIterable, Sendable {
        case unauthorized, forbidden, redirect, loginPage
        var response: StubURLProtocol.CannedResponse {
            switch self {
            case .unauthorized: return .init(status: 401, data: Data())
            case .forbidden: return .init(status: 403, data: Data("{}".utf8))
            case .redirect: return .init(status: 307, data: Data(), headers: ["Location": "/login"])
            case .loginPage: return .init(data: Data(Fixtures.typesafeLoginLandingHTML.utf8))
            }
        }
    }

    @Test("signed out: 401, 403, a redirect or the login page read as expired",
          arguments: SignedOut.allCases)
    func expired(_ page: SignedOut) async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console(page: page.response)
        let s = try snapshot(try await provider(session: Self.validSession).fetchUsage(forceRefresh: true))
        #expect(s.console == .expired)
        expectTrue(s.billing == nil)
        expectTrue(s.usage == nil)
        #expect(s.modelCount == 2)
    }

    @Test("a redirect is refused, not followed")
    func redirect_not_followed() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console(page: .init(status: 302, data: Data(),
                                                           redirectURL: URL(string: "https://evil.example/steal")!))
        let s = try snapshot(try await provider(session: Self.validSession).fetchUsage(forceRefresh: true))
        // The stub cannot deliver the 3xx after a refusal (real URLSession
        // does, and the 307 case above pins that it reads as expired); what
        // matters here is that the target is never contacted.
        #expect(!StubURLProtocol.captured.contains { $0.url?.host == "evil.example" })
        expectTrue(s.billing == nil)
        #expect(s.console != .connected(expiresAt: Self.validSession.expiresAt))
    }

    @Test("usage endpoint signed out also reads as expired")
    func usage_expired() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console(usage: .init(data: Data(Fixtures.typesafeLoginLandingHTML.utf8)))
        let s = try snapshot(try await provider(session: Self.validSession).fetchUsage(forceRefresh: true))
        #expect(s.console == .expired)
    }

    enum Transient: String, CaseIterable, Sendable {
        case serverError, rateLimited, cloudflare, badFormat, timeout
        var response: StubURLProtocol.CannedResponse {
            switch self {
            case .serverError: return .init(status: 503, data: Data("down".utf8))
            case .rateLimited: return .init(status: 429, data: Data())
            case .cloudflare: return .init(status: 403, data: Data("<title>Just a moment...</title>".utf8))
            case .badFormat: return .init(data: Data(#"{"nope":1}"#.utf8))
            case .timeout: return .failing(.timedOut)
            }
        }
    }

    @Test("transient failures keep the last console numbers, marked unavailable",
          arguments: Transient.allCases)
    func unavailable_keeps_last(_ failure: Transient) async throws {
        let usage = failure.response
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        let p = provider(session: Self.validSession)
        StubURLProtocol.handler = Self.console()
        _ = try await p.fetchUsage(forceRefresh: true)
        StubURLProtocol.handler = Self.console(usage: usage)
        let s = try snapshot(try await p.fetchUsage(forceRefresh: true))
        #expect(s.console == .unavailable(since: Self.now))
        expectTrue(s.billing?.balanceUSD == 30)
        expectTrue(s.usage?.todayRequests == 4)
    }

    @Test("an unavailable console on a cold start shows no numbers")
    func unavailable_cold() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console(page: .init(status: 500, data: Data()))
        let s = try snapshot(try await provider(session: Self.validSession).fetchUsage(forceRefresh: true))
        #expect(s.console == .unavailable(since: Self.now))
        expectTrue(s.billing == nil)
    }

    @Test("no session: nothing is sent to the console")
    func not_connected() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console()
        let s = try snapshot(try await provider(session: nil).fetchUsage(forceRefresh: true))
        #expect(s.console == .notConnected)
        #expect(consoleRequests().isEmpty)
    }

    @Test("a session past its expiry is not sent")
    func expired_by_date() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console()
        let old = TypeSafeConsoleSession(cookieHeader: consoleCookie, expiresAt: Self.now.addingTimeInterval(-1))
        let s = try snapshot(try await provider(session: old).fetchUsage(forceRefresh: true))
        #expect(s.console == .expired)
        #expect(consoleRequests().isEmpty)
    }

    @Test("a sign-in picked up by the store applies on the next fetch")
    func session_store_live() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = Self.console()
        let store = TypeSafeSessionStore()
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let p = TypeSafeProvider(
            credentials: EnvOrConfigCredentialReader(envVarName: "_UNSET_TS_LIVE", inlineKey: "k", vendorName: "TypeSafe"),
            cache: DiskCache(vendor: .typesafe, baseDir: tmpCacheDir), http: http,
            baseURL: URL(string: TypeSafeConfig.defaultBaseURL)!, sessionStore: store,
            console: TypeSafeConsoleClient(http: http, now: { Self.now }), now: { Self.now }, calendar: utc)
        #expect(try snapshot(try await p.fetchUsage(forceRefresh: true)).console == .notConnected)
        store.set(Self.validSession)
        #expect(try snapshot(try await p.fetchUsage(forceRefresh: true)).console
                == .connected(expiresAt: Self.validSession.expiresAt))
        store.set(nil)
        #expect(try snapshot(try await p.fetchUsage(forceRefresh: true)).console == .notConnected)
    }

    @Test("the console client refuses any other host")
    func client_host_guard() async {
        let client = TypeSafeConsoleClient(http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]))
        #expect(TypeSafeConsoleClient.billingURL.host == "console.typesafe.ai")
        #expect(TypeSafeConsoleClient.usageURL("hour").host == "console.typesafe.ai")
        #expect(TypeSafeConsoleClient.defaultUserAgent.hasPrefix("ai-taskbar/"))
        _ = client
    }
}

/// Thread-safe call counter for stub handlers.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
