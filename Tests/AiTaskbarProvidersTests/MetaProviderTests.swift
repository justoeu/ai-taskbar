import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// Golden + behavior tests for the Meta (Muse) quota provider. Fixtures are
/// SYNTHETIC (see Fixtures.swift): the field contract comes from
/// docs/SDD-meta-muse.md §2.2; minting a real response spends a login.
@Suite("Meta provider", .serialized)
struct MetaProviderTests {
    let tmpCacheDir: URL

    init() throws {
        StubURLProtocol.reset()
        tmpCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-meta-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCacheDir)
    }

    private struct FakeCredentials: MetaCredentialReading {
        let resolution: MetaLoginResolution
        func resolve() -> MetaLoginResolution { resolution }
        func hasLogin() -> Bool { resolution != .missing }
    }

    private func provider(resolution: MetaLoginResolution = .token("dca:test")) -> MetaProvider {
        MetaProvider(
            credentials: FakeCredentials(resolution: resolution),
            cache: DiskCache(vendor: .meta, baseDir: tmpCacheDir),
            http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]))
    }

    private func snapshot(_ outcome: FetchOutcome) throws -> MetaSnapshot {
        guard case let .meta(s) = outcome.snapshot else {
            Issue.record("expected a meta snapshot")
            throw AppError.schema("wrong vendor")
        }
        return s
    }

    // MARK: weekly carry (SDD-meta-muse §20)

    /// Before the active fixture's weekly reset (1_792_400_000).
    private static let beforeReset = Date(timeIntervalSince1970: 1_792_000_000)

    private func carryingProvider(memory: LastSeenWindowStore, now: Date) -> MetaProvider {
        MetaProvider(
            credentials: FakeCredentials(resolution: .token("dca:test")),
            cache: DiskCache(vendor: .meta, baseDir: tmpCacheDir),
            http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]),
            weeklyMemory: memory,
            clock: { now })
    }

    @Test("idle mint keeps showing the last live weekly reading until its reset")
    func idle_mint_carries_weekly() async throws {
        let memory = LastSeenWindowStore(vendor: .meta, baseDir: tmpCacheDir)
        StubURLProtocol.handler = { _ in .init(data: Fixtures.data(Fixtures.metaMintActive200)) }
        let live = try snapshot(await carryingProvider(memory: memory, now: Self.beforeReset)
            .fetchUsage(forceRefresh: true))
        #expect(live.weekly?.utilizationPercent == 12)
        #expect(live.weeklyLastSeenAt == nil)

        StubURLProtocol.handler = { _ in .init(data: Fixtures.data(Fixtures.metaMintIdle200)) }
        let later = Self.beforeReset.addingTimeInterval(3600)
        let idle = try snapshot(await carryingProvider(memory: memory, now: later)
            .fetchUsage(forceRefresh: true))
        #expect(idle.session == nil)
        #expect(idle.weekly?.utilizationPercent == 12)
        #expect(idle.weekly?.resetsAt == Date(timeIntervalSince1970: 1_792_400_000))
        #expect(idle.weeklyLastSeenAt == Self.beforeReset)

        let afterReset = Date(timeIntervalSince1970: 1_792_400_001)
        let expired = try snapshot(await carryingProvider(memory: memory, now: afterReset)
            .fetchUsage(forceRefresh: true))
        #expect(expired.weekly == nil)
        #expect(expired.weeklyLastSeenAt == nil)
    }

    @Test("the cache holds only what Meta sent, never the carried window")
    func cache_holds_live_response_only() async throws {
        let memory = LastSeenWindowStore(vendor: .meta, baseDir: tmpCacheDir)
        memory.record(UsageWindow(label: "Weekly (7d)", utilizationPercent: 100,
                                  resetsAt: Date(timeIntervalSince1970: 1_792_400_000)),
                      at: Self.beforeReset)
        StubURLProtocol.handler = { _ in .init(data: Fixtures.data(Fixtures.metaMintIdle200)) }
        _ = try await carryingProvider(memory: memory, now: Self.beforeReset)
            .fetchUsage(forceRefresh: true)
        let cached = try #require(DiskCache(vendor: .meta, baseDir: tmpCacheDir).freshPayloadWithAge())
        let raw = try SharedCoders.decoder.decode(MetaSnapshot.self, from: cached.0)
        #expect(raw.weekly == nil)
    }

    @Test("a carried window is not re-recorded as a live reading")
    func carried_window_is_not_rerecorded() async throws {
        let memory = LastSeenWindowStore(vendor: .meta, baseDir: tmpCacheDir)
        memory.record(UsageWindow(label: "Weekly (7d)", utilizationPercent: 100,
                                  resetsAt: Date(timeIntervalSince1970: 1_792_400_000)),
                      at: Self.beforeReset)
        StubURLProtocol.handler = { _ in .init(data: Fixtures.data(Fixtures.metaMintIdle200)) }
        let later = Self.beforeReset.addingTimeInterval(2 * LastSeenWindowStore.refreshInterval)
        _ = try await carryingProvider(memory: memory, now: later).fetchUsage(forceRefresh: true)
        #expect(memory.load()?.observedAt == Self.beforeReset)
    }

    // MARK: golden

    @Test("golden: mint response decodes field by field")
    func golden_active() throws {
        let s = try SharedCoders.decoder
            .decode(MetaMintResponse.self, from: Fixtures.data(Fixtures.metaMintActive200))
            .toSnapshot()
        #expect(s.planLabel == "Muse Code Power Usage")
        #expect(s.subscription == .active)
        #expect(s.session?.label == "Session (5h)")
        #expect(s.session?.utilizationPercent == 37.5)
        #expect(s.session?.resetsAt == Date(timeIntervalSince1970: 1_791_900_000))
        #expect(s.weekly?.label == "Weekly (7d)")
        #expect(s.weekly?.utilizationPercent == 12.0)
        #expect(s.weekly?.resetsAt == Date(timeIntervalSince1970: 1_792_400_000))
        #expect(s.weeklyLastSeenAt == nil)
        let vendor = VendorSnapshot.meta(s)
        #expect(vendor.windows.count == 2)
        #expect(vendor.maxUtilization == 37.5)
    }

    @Test("golden: idle keeps plan, invents no windows")
    func golden_idle() throws {
        let s = try SharedCoders.decoder
            .decode(MetaMintResponse.self, from: Fixtures.data(Fixtures.metaMintIdle200))
            .toSnapshot()
        #expect(s.subscription == .active)
        #expect(s.planLabel == "Muse Code Power Usage")
        #expect(s.session == nil)
        #expect(s.weekly == nil)
    }

    @Test("golden: pay-as-you-go and billing-incomplete states")
    func golden_payg_billing() throws {
        let payg = try SharedCoders.decoder
            .decode(MetaMintResponse.self, from: Fixtures.data(Fixtures.metaMintPayg200))
            .toSnapshot()
        #expect(payg.subscription == .payAsYouGo)
        #expect(payg.session == nil)
        let billing = try SharedCoders.decoder
            .decode(MetaMintResponse.self, from: Fixtures.data(Fixtures.metaMintBilling200))
            .toSnapshot()
        #expect(billing.subscription == .billingIncomplete)
    }

    @Test("out-of-range resets_at drops the date, keeps the percent")
    func bad_resets_at() throws {
        let body = #"{"is_subs_active":true,"subs_usage":{"window":{"used_percent":50,"resets_at":9.9e18,"window_duration_mins":300},"weekly":{"used_percent":10,"resets_at":0}}}"#
        let s = try SharedCoders.decoder.decode(MetaMintResponse.self,
                                                from: Fixtures.data(body)).toSnapshot()
        #expect(s.session?.utilizationPercent == 50)
        #expect(s.session?.resetsAt == nil)
        #expect(s.weekly?.resetsAt == nil)
    }

    @Test("unrecognized mint body is schema drift, never a fake pay-as-you-go")
    func unrecognized_body_throws() {
        for body in ["{}", #"{"maintenance":true}"#] {
            #expect(throws: AppError.self) {
                try SharedCoders.decoder.decode(MetaMintResponse.self,
                                                from: Fixtures.data(body)).toSnapshot()
            }
        }
    }

    @Test("windows are independent; a present window needs a usable percent")
    func independent_windows() throws {
        // Weekly only, no session window/duration: weekly survives.
        let body = #"{"is_subs_active":true,"subs_usage":{"weekly":{"used_percent":25}}}"#
        let s = try SharedCoders.decoder.decode(MetaMintResponse.self,
                                                from: Fixtures.data(body)).toSnapshot()
        #expect(s.session == nil)
        #expect(s.weekly?.utilizationPercent == 25)
        // Present session window without percent is drift.
        let bad = #"{"is_subs_active":true,"subs_usage":{"window":{"window_duration_mins":300}}}"#
        #expect(throws: AppError.self) {
            try SharedCoders.decoder.decode(MetaMintResponse.self,
                                            from: Fixtures.data(bad)).toSnapshot()
        }
    }

    // MARK: request discipline

    @Test("the only request ever built is the mint POST")
    func mint_request_shape() {
        let req = provider().mintRequest(token: "dca:test")
        #expect(req.url?.absoluteString == "https://api.meta.ai/muse-code/key")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer dca:test")
        #expect(req.value(forHTTPHeaderField: "x-api-version") == "1.0.0")
    }

    @Test("fetch mints, maps windows, and caches no secret material")
    func fetch_end_to_end() async throws {
        StubURLProtocol.handler = { _ in .init(data: Fixtures.data(Fixtures.metaMintActive200)) }
        let outcome = try await provider().fetchUsage(forceRefresh: true)
        let s = try snapshot(outcome)
        #expect(s.subscription == .active)
        #expect(StubURLProtocol.captured.map { $0.url?.absoluteString }
                == ["https://api.meta.ai/muse-code/key"])
        // The cached payload is the interpreted snapshot: the minted key,
        // email and payment block from the wire must not be on disk.
        let cache = DiskCache(vendor: .meta, baseDir: tmpCacheDir)
        let cached = try #require(cache.anyPayload())
        let text = String(decoding: cached, as: UTF8.self)
        expectFalse(text.contains("LLM|"))
        expectFalse(text.contains("4242"))
        expectFalse(text.contains("user@example.com"))
        expectFalse(text.contains("dca:test"))
    }

    @Test("401/403/429/5xx/3xx from the mint are HTTP failures")
    func fetch_http_failures() async {
        for status in [401, 403, 429, 500, 302] {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { _ in .init(status: status, data: Data()) }
            do {
                _ = try await provider().fetchUsage(forceRefresh: true)
                Issue.record("expected HTTP \(status) to throw")
            } catch let e as AppError {
                #expect(e.httpStatus == status)
                expectTrue(e.isRateLimited == (status == 429))
            } catch {
                Issue.record("expected AppError for \(status), got \(error)")
            }
        }
    }

    @Test("a later failure serves the stale snapshot")
    func fetch_stale_after_success() async throws {
        StubURLProtocol.handler = { _ in .init(data: Fixtures.data(Fixtures.metaMintActive200)) }
        let p = provider()
        _ = try await p.fetchUsage(forceRefresh: true)
        StubURLProtocol.handler = { _ in .init(status: 500, data: Data()) }
        let outcome = try await p.fetchUsage(forceRefresh: true)
        expectTrue(outcome.isStale)
        #expect(try snapshot(outcome).subscription == .active)
    }

    @Test("non-finite or over-range percents never reach a window raw")
    func percent_sanitization() throws {
        func snap(percent: Double) throws -> MetaSnapshot {
            try MetaMintResponse(
                isSubsActive: true, requirePayment: false, subsTierName: nil,
                subsUsage: .init(
                    window: .init(usedPercent: percent, resetsAt: nil, windowDurationMins: 300),
                    weekly: .init(usedPercent: 1, resetsAt: nil, windowDurationMins: nil)))
                .toSnapshot()
        }
        #expect(throws: AppError.self) { try snap(percent: .nan) }
        #expect(throws: AppError.self) { try snap(percent: .infinity) }
        #expect(try snap(percent: 150).session?.utilizationPercent == 100)
        #expect(try snap(percent: -5).session?.utilizationPercent == 0)
    }

    @Test("missing login is quiet guidance and never reaches the network")
    func fetch_missing_login() async {
        StubURLProtocol.handler = { _ in .init(data: Data()) }
        do {
            _ = try await provider(resolution: .missing).fetchUsage(forceRefresh: true)
            Issue.record("expected guidance")
        } catch let e as AppError {
            #expect(e == .guidance(.museLoginRequired))
        } catch {
            Issue.record("expected AppError, got \(error)")
        }
        #expect(StubURLProtocol.captured.isEmpty)
    }

    @Test("blocked Keychain surfaces the ACL affordance shape, no network")
    func fetch_blocked_keychain() async {
        StubURLProtocol.handler = { _ in .init(data: Data()) }
        do {
            _ = try await provider(resolution: .keychainBlocked).fetchUsage(forceRefresh: true)
            Issue.record("expected ACL-blocked credentials error")
        } catch let e as AppError {
            expectTrue(e.isKeychainACLBlocked)
        } catch {
            Issue.record("expected AppError, got \(error)")
        }
        #expect(StubURLProtocol.captured.isEmpty)
    }

    @Test("authorize delegates to the credential reader")
    func authorize_delegates() throws {
        final class Fake: MetaCredentialReading, @unchecked Sendable {
            var calls = 0
            func resolve() -> MetaLoginResolution { .missing }
            func hasLogin() -> Bool { false }
            func authorizePersistently() throws -> Bool { calls += 1; return true }
        }
        let fake = Fake()
        let p = MetaProvider(credentials: fake,
                             cache: DiskCache(vendor: .meta, baseDir: tmpCacheDir),
                             http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]))
        expectTrue(try p.authorizeCredentialsInteractively())
        #expect(fake.calls == 1)
    }

    private final class DiscardingCredentials: MetaCredentialReading, @unchecked Sendable {
        let resolution: MetaLoginResolution
        private let lock = NSLock()
        private var _discarded: [String] = []
        var discarded: [String] { lock.withLock { _discarded } }
        init(_ resolution: MetaLoginResolution) { self.resolution = resolution }
        func resolve() -> MetaLoginResolution { resolution }
        func hasLogin() -> Bool { true }
        func discardStoredToken(_ token: String) -> Bool {
            lock.withLock { _discarded.append(token) }
            return true
        }
    }

    private func fetchError(_ creds: DiscardingCredentials, status: Int) async -> AppError? {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in .init(status: status, data: Data()) }
        let p = MetaProvider(credentials: creds,
                             cache: DiskCache(vendor: .meta, baseDir: tmpCacheDir),
                             http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]))
        do {
            _ = try await p.fetchUsage(forceRefresh: true)
            Issue.record("expected HTTP \(status) to throw")
            return nil
        } catch let e as AppError {
            return e
        } catch {
            Issue.record("expected AppError, got \(error)")
            return nil
        }
    }

    @Test("a 401 on the stored copy drops it and shows the Authorize banner")
    func rejected_copy_is_discarded() async throws {
        let creds = DiscardingCredentials(.storedToken("dca:stored-copy"))
        let e = try #require(await fetchError(creds, status: 401))
        expectTrue(e.isKeychainACLBlocked)
        #expect(creds.discarded == ["dca:stored-copy"])
    }

    @Test("a 401 on a LIVE Keychain token is a dead login, not an ACL block")
    func rejected_live_token_is_relogin() async throws {
        let creds = DiscardingCredentials(.token("dca:live"))
        let e = try #require(await fetchError(creds, status: 401))
        expectFalse(e.isKeychainACLBlocked)
        #expect(e.httpStatus == 401)
        #expect(creds.discarded == ["dca:live"])  // its copy is dead too
    }

    @Test("a 403 keeps the stored copy")
    func forbidden_keeps_copy() async throws {
        let creds = DiscardingCredentials(.storedToken("dca:stored-copy"))
        let e = try #require(await fetchError(creds, status: 403))
        #expect(e.httpStatus == 403)
        #expect(creds.discarded.isEmpty)
    }
}
