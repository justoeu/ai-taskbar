import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// Golden + behavior tests for the TypeSafe (Jev) API-key heartbeat. The
/// fixtures are verbatim responses captured on 2026-09-29.
@Suite("TypeSafe provider", .serialized)
struct TypeSafeProviderTests {
    let tmpCacheDir: URL

    init() throws {
        StubURLProtocol.reset()
        tmpCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-typesafe-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCacheDir)
    }

    private func provider(key: String = "ts-test-key") -> TypeSafeProvider {
        TypeSafeProvider(
            credentials: EnvOrConfigCredentialReader(envVarName: "_UNSET_TYPESAFE_\(UUID().uuidString.prefix(6))",
                                                     inlineKey: key, vendorName: "TypeSafe"),
            cache: DiskCache(vendor: .typesafe, baseDir: tmpCacheDir),
            http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]),
            baseURL: URL(string: TypeSafeConfig.defaultBaseURL)!
        )
    }

    private func snapshot(_ outcome: FetchOutcome) throws -> TypeSafeSnapshot {
        guard case let .typesafe(s) = outcome.snapshot else {
            Issue.record("expected a typesafe snapshot")
            throw AppError.schema("wrong vendor")
        }
        return s
    }

    // MARK: golden

    @Test("golden: /v1/models decodes field by field")
    func golden_models() throws {
        let parsed = try SharedCoders.decoder.decode(TypeSafeModelsResponse.self,
                                                     from: Fixtures.data(Fixtures.typesafeModels200))
        let s = parsed.toSnapshot()
        #expect(s.modelCount == 2)
        #expect(s.models.map(\.name) == ["jev-latest", "jev-preview"])
        #expect(s.models[0].description == "The latest iteration of TypeSafe's System One Model: Jev")
        #expect(s.models[1].description == "A preview version of `jev-latest`: should be better in most ways")
        // Microsecond precision parses (ISO8601Parsing tries fractional first).
        let d0 = try #require(s.models[0].releaseDate)
        let d1 = try #require(s.models[1].releaseDate)
        #expect(abs(d0.timeIntervalSince1970 - 1_789_065_481.391457) < 0.001)
        #expect(abs(d1.timeIntervalSince1970 - 1_789_065_546.057655) < 0.001)
        expectTrue(s.lastUpdated == s.models[1].releaseDate)
        expectTrue(s.billing == nil)
        expectTrue(s.planLabel == nil)
    }

    @Test("no quota: no windows, zero utilization, nothing for the menu bar")
    func no_utilization() throws {
        let s = try SharedCoders.decoder.decode(TypeSafeModelsResponse.self,
                                                from: Fixtures.data(Fixtures.typesafeModels200)).toSnapshot()
        let snap = VendorSnapshot.typesafe(s)
        #expect(snap.windows.isEmpty)
        #expect(snap.maxUtilization == 0)
        expectTrue(snap.menuBarDisplayPercentages.weekly == nil)
        expectTrue(snap.menuBarResetWindows.weekly == nil)
        #expect(snap.vendorId == .typesafe)
    }

    @Test("entries without a usable name are skipped, not fatal")
    func skips_bad_entries() throws {
        let body = #"{"models":[{"name":""},{"description":"no name"},{"name":"jev-latest","release_date":"not a date"}]}"#
        let s = try SharedCoders.decoder.decode(TypeSafeModelsResponse.self, from: Fixtures.data(body)).toSnapshot()
        #expect(s.models.map(\.name) == ["jev-latest"])
        expectTrue(s.models[0].releaseDate == nil)
    }

    @Test("a body without `models` is a schema error")
    func missing_models_is_schema_error() {
        #expect(throws: (any Error).self) {
            _ = try SharedCoders.decoder.decode(TypeSafeModelsResponse.self, from: Fixtures.data(#"{"data":[]}"#))
        }
    }

    @Test("error body decodes both detail shapes")
    func error_bodies() throws {
        let auth = try SharedCoders.decoder.decode(TypeSafeErrorResponse.self,
                                                   from: Fixtures.data(Fixtures.typesafeInvalidKey401))
        #expect(auth.errorType == "authentication_error")
        #expect(auth.message == "Cannot authenticate with the server. Please check your API key and try again.")
        let notFound = try SharedCoders.decoder.decode(TypeSafeErrorResponse.self,
                                                       from: Fixtures.data(Fixtures.typesafeNotFound404))
        expectTrue(notFound.errorType == nil)
        #expect(notFound.message == "Not Found")
    }

    // MARK: provider behavior

    @Test("fetch sends Bearer to GET /v1/models and nothing else")
    func only_models_request() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = { _ in .init(data: Fixtures.data(Fixtures.typesafeModels200)) }
        let s = try snapshot(try await provider().fetchUsage(forceRefresh: true))
        #expect(s.modelCount == 2)
        let reqs = StubURLProtocol.captured.filter { $0.url?.host == "api.typesafe.ai" }
        #expect(reqs.count == 1)
        #expect(reqs.first?.url?.path == "/v1/models")
        #expect(reqs.first?.httpMethod == "GET")
        #expect(reqs.first?.value(forHTTPHeaderField: "Authorization") == "Bearer ts-test-key")
        // Evaluations bill tokens: the provider must never target them.
        #expect(!StubURLProtocol.captured.contains { $0.url?.path.contains("systemone") == true })
    }

    @Test("the request builder only ever targets /v1/models")
    func request_builder_path() {
        let r = provider().modelsRequest(apiKey: "k")
        #expect(r.url?.absoluteString == "https://api.typesafe.ai/v1/models")
        #expect(r.httpMethod == "GET")
    }

    @Test("401 invalid key surfaces as HTTP 401 on a cold cache")
    func invalid_key_401() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = { _ in .init(status: 401, data: Fixtures.data(Fixtures.typesafeInvalidKey401)) }
        do {
            _ = try await provider().fetchUsage(forceRefresh: true)
            Issue.record("expected a 401")
        } catch let e as AppError {
            #expect(e.httpStatus == 401)
        }
    }

    @Test("403 authentication_error is normalized to 401")
    func missing_key_403_normalized() {
        let normalized = TypeSafeProvider.normalize(.http(status: 403, body: Fixtures.typesafeMissingKey403))
        #expect(normalized.httpStatus == 401)
        // A 403 without the authentication marker is left alone.
        #expect(TypeSafeProvider.normalize(.http(status: 403, body: "{}")).httpStatus == 403)
        #expect(TypeSafeProvider.normalize(.http(status: 404, body: Fixtures.typesafeNotFound404)).httpStatus == 404)
    }

    @Test("a failure after a good fetch serves the cached snapshot as stale")
    func stale_fallback() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        let p = provider()
        StubURLProtocol.handler = { _ in .init(data: Fixtures.data(Fixtures.typesafeModels200)) }
        _ = try await p.fetchUsage(forceRefresh: true)
        StubURLProtocol.handler = { _ in .init(status: 529, data: Data("overloaded".utf8)) }
        let outcome = try await p.fetchUsage(forceRefresh: true)
        #expect(outcome.isStale)
        #expect(try snapshot(outcome).modelCount == 2)
    }

    @Test("the API key never reaches the cache or the stored error")
    func key_not_persisted() async throws {
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: tmpCacheDir) }
        StubURLProtocol.handler = { _ in .init(status: 401, data: Fixtures.data(Fixtures.typesafeInvalidKey401)) }
        _ = try? await provider(key: "ts-SECRET-marker-123").fetchUsage(forceRefresh: true)
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: tmpCacheDir.path)) ?? []
        for f in files {
            let text = (try? String(contentsOf: tmpCacheDir.appendingPathComponent(f), encoding: .utf8)) ?? ""
            #expect(!text.contains("ts-SECRET-marker-123"), "leaked into \(f)")
        }
    }
}

/// TypeSafe's status feed publishes one item per incident UPDATE.
@Suite("TypeSafe status feed")
struct TypeSafeStatusFeedTests {
    private func status(at iso: String) throws -> VendorServiceStatus {
        let source = RSSStatusSource(descriptor: .typeSafe)
        let feed = try RSSStatusSource.parse(Fixtures.data(Fixtures.typesafeStatusRSS200))
        return try source.makeStatus(from: feed, now: ISO8601Parsing.parse(iso)!)
    }

    @Test("updates of one incident merge; the newest decides the state")
    func merges_updates() throws {
        // 20:00 UTC: maintenance #1077524 had two updates (15:02 in progress,
        // 15:32 completed) — it must appear once, completed.
        let st = try status(at: "2026-09-29T20:00:00Z")
        let maint = st.incidents.filter { $0.id.hasSuffix("/maintenance/1077524") }
        #expect(maint.count == 1)
        #expect(maint.first?.phase == .completed)
        expectTrue(maint.first?.startedAt == ISO8601Parsing.parse("2026-09-29T15:02:44Z"))
        // #1070098 at 20:00 only has its 21/09 "fully resolved" update: out.
        #expect(!st.incidents.contains { $0.id.hasSuffix("/incident/1070098") })
        #expect(st.level == .unknown)
    }

    @Test("an unresolved incident abandoned for > 48 h is not ongoing")
    func drops_stale_unresolved() throws {
        // #1070670 "API issues" (21/09) only ever published "investigating".
        let st = try status(at: "2026-09-29T20:00:00Z")
        #expect(!st.incidents.contains { $0.id.hasSuffix("/incident/1070670") })
        #expect(st.level != .degradedPerformance)
    }

    @Test("a fresh unresolved update counts as active")
    func fresh_update_is_active() throws {
        // 22:30 UTC: #1070098 got a new "console may experience issues due to
        // regularly applied maintenance" update at 22:05.
        let st = try status(at: "2026-09-29T22:30:00Z")
        #expect(st.coverage == .incidentsOnly)
        #expect(st.level == .maintenance)
        #expect(st.incidents.contains { $0.id.hasSuffix("/incident/1070098") && $0.resolvedAt == nil })
    }

    @Test("other RSS descriptors keep per-item behavior")
    func other_descriptors_unchanged() {
        #expect(!RSSStatusDescriptor.xAI.groupsUpdatesByIncidentLink)
        expectTrue(RSSStatusDescriptor.xAI.staleUnresolvedAfter == nil)
        #expect(!RSSStatusDescriptor.openRouter.groupsUpdatesByIncidentLink)
        expectTrue(RSSStatusDescriptor.openRouter.staleUnresolvedAfter == nil)
        #expect(ServiceStatusProviderFactory.rssDescriptor(for: .typesafe) == .typeSafe)
        expectTrue(ServiceStatusProviderFactory.descriptor(for: .typesafe) == nil)
    }
}

/// The production path: `CachedServiceStatusProvider` → `fetchPayload`, which
/// validates the descriptor and the channel identity before parsing. The
/// tests above call `makeStatus` directly and could not see that both checks
/// rejected TypeSafe on every fetch.
@Suite("TypeSafe status feed, fetched", .serialized)
struct TypeSafeStatusFetchTests {
    @Test("the TypeSafe feed is fetched, validated and parsed end to end")
    func fetched_end_to_end() async throws {
        StubURLProtocol.reset()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-typesafe-status-\(UUID().uuidString)")
        try Paths.ensureDir(dir)
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: dir) }
        StubURLProtocol.handler = { _ in .init(data: Fixtures.data(Fixtures.typesafeStatusRSS200)) }
        let provider = CachedServiceStatusProvider(
            source: RSSStatusSource(descriptor: .typeSafe),
            cache: DiskCache(vendor: .typesafe, baseDir: dir, ttl: 300, maxStale: ServiceStatusWindow.duration),
            http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]))
        let outcome = try await provider.fetchStatus(forceRefresh: true,
                                                     now: ISO8601Parsing.parse("2026-09-29T22:30:00Z")!)
        #expect(outcome.snapshot.vendorId == .typesafe)
        #expect(outcome.snapshot.level == .maintenance)
        #expect(StubURLProtocol.captured.count == 1)
        #expect(StubURLProtocol.captured.first?.url == RSSStatusDescriptor.typeSafe.feedURL)
    }
}
