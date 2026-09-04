import Testing
import AiTaskbarTestSupport
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("FlashDuty and RSS service-status providers", .serialized)
struct SecondaryStatusProviderTests {
    init() { StubURLProtocol.reset() }

    private var fixtureNow: Date {
        ISO8601Parsing.parse("2026-09-03T12:00:00Z")!
    }

    private func temporaryCache(
        vendor: VendorId,
        ttl: TimeInterval = 300
    ) throws -> DiskCache {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-secondary-status-\(UUID().uuidString)")
        try Paths.ensureDir(dir)
        return DiskCache(
            vendor: vendor,
            baseDir: dir,
            ttl: ttl,
            maxStale: ServiceStatusWindow.duration
        )
    }

    private func remove(_ cache: DiskCache) {
        try? FileManager.default.removeItem(at: cache.baseDir)
    }

    private func installDeepSeekSuccess() {
        StubURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/status-page/6410630422455/summary/active":
                return .init(data: Fixtures.data(Fixtures.deepseekStatusActive200))
            case "/api/status-page/6410630422455/summary/structure":
                return .init(data: Fixtures.data(Fixtures.deepseekStatusStructure200))
            case "/api/status-page/6410630422455/change/list":
                return .init(data: Fixtures.data(Fixtures.deepseekStatusChanges200))
            default:
                return .init(status: 404, data: Data("missing".utf8))
            }
        }
    }

    private func makeDeepSeekProvider(
        cache: DiskCache,
        http: HTTPClient? = nil
    ) -> CachedServiceStatusProvider<DeepSeekStatusSource> {
        CachedServiceStatusProvider(
            source: DeepSeekStatusSource(referenceDate: fixtureNow),
            cache: cache,
            http: http ?? HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        )
    }

    private func makeRSSProvider(
        descriptor: RSSStatusDescriptor,
        cache: DiskCache,
        http: HTTPClient? = nil
    ) -> CachedServiceStatusProvider<RSSStatusSource> {
        CachedServiceStatusProvider(
            source: RSSStatusSource(descriptor: descriptor),
            cache: cache,
            http: http ?? HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        )
    }

    private func deepSeekPayload() throws -> DeepSeekStatusPayload {
        let active = try JSONDecoder().decode(
            DeepSeekStatusEnvelope<DeepSeekActiveStatus>.self,
            from: Fixtures.data(Fixtures.deepseekStatusActive200)
        )
        let structure = try JSONDecoder().decode(
            DeepSeekStatusEnvelope<DeepSeekStatusStructure>.self,
            from: Fixtures.data(Fixtures.deepseekStatusStructure200)
        )
        let changes = try JSONDecoder().decode(
            DeepSeekStatusEnvelope<DeepSeekChangeList>.self,
            from: Fixtures.data(Fixtures.deepseekStatusChanges200)
        )
        return DeepSeekStatusPayload(
            active: active,
            structure: structure,
            changes: changes
        )
    }

    @Test("DeepSeek requests the three official bounded-window endpoints")
    func deepseek_official_endpoints() async throws {
        installDeepSeekSuccess()
        let cache = try temporaryCache(vendor: .deepseek)
        defer { remove(cache); StubURLProtocol.reset() }

        _ = try await makeDeepSeekProvider(cache: cache)
            .fetchStatus(forceRefresh: true, now: fixtureNow)

        let requests = StubURLProtocol.captured
        #expect(requests.count == 3)
        expectTrue(Set(requests.compactMap(\.url?.path)) == [
            "/api/status-page/6410630422455/summary/active",
            "/api/status-page/6410630422455/summary/structure",
            "/api/status-page/6410630422455/change/list",
        ])
        expectTrue(requests.allSatisfy { $0.url?.scheme == "https" })
        expectTrue(requests.allSatisfy { $0.url?.host == "status.deepseek.com" })
        expectTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        expectTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == nil
        })
        let structure = try #require(requests.first {
            $0.url?.path.hasSuffix("/summary/structure") == true
        })
        let structureURL = try #require(structure.url)
        let structureComponents = try #require(
            URLComponents(url: structureURL, resolvingAgainstBaseURL: false)
        )
        let structureItems = try #require(structureComponents.queryItems)
        expectTrue(structureItems.first {
            $0.name == "start_at_from_seconds"
        }?.value == "1788415200")
        expectTrue(structureItems.first {
            $0.name == "start_at_to_seconds"
        }?.value == "1788436800")
        let changes = try #require(requests.first {
            $0.url?.path.hasSuffix("/change/list") == true
        })
        let changesURL = try #require(changes.url)
        let changesComponents = try #require(
            URLComponents(url: changesURL, resolvingAgainstBaseURL: false)
        )
        let changeItems = try #require(changesComponents.queryItems)
        expectTrue(changeItems.first {
            $0.name == "start_at_seconds"
        }?.value == "1788415200")
        expectTrue(changeItems.first {
            $0.name == "end_at_seconds"
        }?.value == "1788436800")
    }

    @Test("DeepSeek maps explicit state, deduplicates, and applies six-hour intersection")
    func deepseek_mapping() throws {
        let source = DeepSeekStatusSource(referenceDate: fixtureNow)
        let payload = try deepSeekPayload()

        let status = try source.makeStatus(from: payload, now: fixtureNow)

        #expect(status.vendorId == .deepseek)
        #expect(status.level == .partialOutage)
        #expect(status.coverage == .full)
        #expect(status.summary == "API partially unavailable")
        expectTrue(status.sourceURL == URL(string: "https://status.deepseek.com"))
        expectTrue(status.sourceUpdatedAt == ISO8601Parsing.parse("2026-09-03T11:50:00Z"))
        #expect(status.incidents.map(\.id) == ["7001", "7002"])
        #expect(status.incidents[0].phase == .monitoring)
        #expect(status.incidents[0].level == .partialOutage)
        #expect(status.incidents[0].affectedComponents == ["API Service"])
        expectTrue(status.incidents[0].message == "A fix is deployed; monitoring recovery.")
        #expect(status.incidents[1].phase == .resolved)
        #expect(status.incidents[1].level == .majorOutage)
        expectTrue(status.incidents[1].resolvedAt == ISO8601Parsing.parse("2026-09-03T10:00:00Z"))
    }

    @Test("RSS descriptors map active incidents but never infer operational")
    func rss_mapping_and_coverage() throws {
        let openRouter = RSSStatusSource(descriptor: .openRouter)
        let openRouterFeed = try RSSStatusSource.parse(
            Fixtures.data(Fixtures.openRouterStatusRSS200)
        )
        let status = try openRouter.makeStatus(from: openRouterFeed, now: fixtureNow)

        #expect(status.vendorId == .openrouter)
        #expect(status.coverage == .incidentsOnly)
        #expect(status.level == .partialOutage)
        #expect(status.summary == "Hostile link outage")
        #expect(status.incidents.map(\.id) == ["duplicate-guid", "incident-hostile", "incident-long"])
        #expect(status.incidents[0].title == "API & routing degraded")
        expectTrue(status.incidents[0].message?.contains("Newer duplicate update.") == true)
        expectTrue(status.incidents[1].sourceURL == nil)
        #expect(status.incidents[2].level == .majorOutage)

        let emptyFeed = RSSStatusFeed(
            title: "Empty",
            link: nil,
            description: nil,
            lastBuildDate: "Thu, 03 Sep 2026 12:00:00 GMT",
            items: []
        )
        let empty = try openRouter.makeStatus(from: emptyFeed, now: fixtureNow)
        #expect(empty.coverage == .incidentsOnly)
        #expect(empty.level == .unknown)
        #expect(empty.incidents.count == 0)
    }

    @Test("xAI parses explicit resolution timestamps and safe incident links")
    func xai_mapping() throws {
        let source = RSSStatusSource(descriptor: .xAI)
        let feed = try RSSStatusSource.parse(Fixtures.data(Fixtures.xaiStatusRSS200))
        let status = try source.makeStatus(from: feed, now: fixtureNow)

        #expect(status.vendorId == .xai)
        #expect(status.coverage == .incidentsOnly)
        #expect(status.level == .majorOutage)
        #expect(status.incidents.map(\.id) == ["INCactive", "INCresolved"])
        #expect(status.incidents[0].phase == .investigating)
        #expect(status.incidents[0].level == .majorOutage)
        expectTrue(status.incidents[0].sourceURL == URL(string: "https://status.x.ai/api-us-east-1/INCactive"))
        #expect(status.incidents[1].phase == .resolved)
        expectTrue(status.incidents[1].resolvedAt == ISO8601Parsing.parse("2026-09-03T10:30:00Z"))
        expectTrue(status.sourceUpdatedAt == ISO8601Parsing.parse("2026-09-03T11:58:00Z"))
    }

    @Test("RSS performs one exact-host HTTPS GET without credentials")
    func rss_official_endpoint() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.openRouterStatusRSS200))
        }
        let cache = try temporaryCache(vendor: .openrouter)
        defer { remove(cache); StubURLProtocol.reset() }
        let provider = makeRSSProvider(descriptor: .openRouter, cache: cache)

        _ = try await provider.fetchStatus(forceRefresh: true, now: fixtureNow)

        #expect(StubURLProtocol.captured.count == 1)
        let request = StubURLProtocol.captured[0]
        expectTrue(request.url == URL(string: "https://status.openrouter.ai/incidents.rss"))
        expectTrue(request.httpMethod == "GET")
        expectTrue(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("secondary sources cap each response at two MiB")
    func payload_limit() async throws {
        let oversized = Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1)
        StubURLProtocol.handler = { _ in .init(data: oversized) }

        let deepSeekCache = try temporaryCache(vendor: .deepseek)
        defer { remove(deepSeekCache) }
        do {
            _ = try await makeDeepSeekProvider(cache: deepSeekCache)
                .fetchStatus(forceRefresh: true, now: fixtureNow)
            Issue.record("expected oversized DeepSeek response")
        } catch let error as AppError {
            guard case .schema(let message) = error else {
                Issue.record("expected schema error, got \(error)")
                return
            }
            expectTrue(message.contains("2 MiB"))
        }

        let rssCache = try temporaryCache(vendor: .openrouter)
        defer { remove(rssCache) }
        do {
            _ = try await makeRSSProvider(descriptor: .openRouter, cache: rssCache)
                .fetchStatus(forceRefresh: true, now: fixtureNow)
            Issue.record("expected oversized RSS response")
        } catch let error as AppError {
            guard case .schema(let message) = error else {
                Issue.record("expected schema error, got \(error)")
                return
            }
            expectTrue(message.contains("2 MiB"))
        }
        StubURLProtocol.reset()
    }

    @Test("RSS rejects excessive item count and bounds emitted text")
    func rss_bounds() throws {
        let item = "<item><title>x</title><description>y</description><pubDate>Thu, 03 Sep 2026 11:00:00 GMT</pubDate></item>"
        let excessive = "<rss><channel>" + String(repeating: item, count: 201) + "</channel></rss>"
        do {
            _ = try RSSStatusSource.parse(Data(excessive.utf8))
            Issue.record("expected item-count limit")
        } catch let error as AppError {
            guard case .schema(let message) = error else {
                Issue.record("expected schema error, got \(error)")
                return
            }
            expectTrue(message.contains("item limit"))
        }

        let longTitle = String(repeating: "t", count: 1_000)
        let xml = "<rss><channel><item><title>\(longTitle)</title><description>x</description><pubDate>Thu, 03 Sep 2026 11:00:00 GMT</pubDate></item></channel></rss>"
        let feed = try RSSStatusSource.parse(Data(xml.utf8))
        let status = try RSSStatusSource(descriptor: .openRouter)
            .makeStatus(from: feed, now: fixtureNow)
        #expect(status.incidents[0].title.count == 300)
    }

    @Test("invalid descriptors and invalid schemas fail before cache write")
    func schema_and_descriptor_validation() async throws {
        let invalidDescriptor = RSSStatusDescriptor(
            vendorId: .openrouter,
            statusPageURL: URL(string: "https://status.openrouter.ai")!,
            feedURL: URL(string: "https://attacker.example/incidents.rss")!
        )
        let cache = try temporaryCache(vendor: .openrouter)
        defer { remove(cache); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            Issue.record("invalid descriptor must not perform network I/O")
            return .init(data: Data())
        }
        do {
            _ = try await makeRSSProvider(descriptor: invalidDescriptor, cache: cache)
                .fetchStatus(forceRefresh: true, now: fixtureNow)
            Issue.record("expected descriptor failure")
        } catch let error as AppError {
            guard case .schema = error else {
                Issue.record("expected schema error, got \(error)")
                return
            }
        }
        #expect(StubURLProtocol.captured.count == 0)

        StubURLProtocol.handler = { _ in .init(data: Data("{}".utf8)) }
        let deepSeekSchemaCache = try temporaryCache(vendor: .deepseek)
        defer { remove(deepSeekSchemaCache) }
        do {
            _ = try await makeDeepSeekProvider(cache: deepSeekSchemaCache)
                .fetchStatus(forceRefresh: true, now: fixtureNow)
            Issue.record("expected DeepSeek schema failure")
        } catch let error as AppError {
            guard case .schema = error else {
                Issue.record("expected schema error, got \(error)")
                return
            }
        }

        StubURLProtocol.handler = { _ in .init(data: Data("not xml".utf8)) }
        let schemaCache = try temporaryCache(vendor: .xai)
        defer { remove(schemaCache) }
        do {
            _ = try await makeRSSProvider(descriptor: .xAI, cache: schemaCache)
                .fetchStatus(forceRefresh: true, now: fixtureNow)
            Issue.record("expected RSS schema failure")
        } catch let error as AppError {
            guard case .schema = error else {
                Issue.record("expected schema error, got \(error)")
                return
            }
        }
    }

    @Test("503 returns stale secondary cache and throws on cold cache")
    func stale_and_cold() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.openRouterStatusRSS200))
        }
        let warmCache = try temporaryCache(vendor: .openrouter, ttl: 0)
        defer { remove(warmCache); StubURLProtocol.reset() }
        let warm = makeRSSProvider(descriptor: .openRouter, cache: warmCache)
        _ = try await warm.fetchStatus(forceRefresh: true, now: fixtureNow)

        StubURLProtocol.handler = { _ in
            .init(status: 503, data: Data("unavailable".utf8))
        }
        let stale = try await warm.fetchStatus(forceRefresh: true, now: fixtureNow)
        expectTrue(stale.isStale)
        expectTrue(stale.lastError?.status == 503)

        let coldCache = try temporaryCache(vendor: .xai, ttl: 0)
        defer { remove(coldCache) }
        do {
            _ = try await makeRSSProvider(descriptor: .xAI, cache: coldCache)
                .fetchStatus(forceRefresh: true, now: fixtureNow)
            Issue.record("expected cold 503")
        } catch let error as AppError {
            guard case .http(let status, _) = error else {
                Issue.record("expected HTTP error, got \(error)")
                return
            }
            #expect(status == 503)
        }
    }

    @Test("secondary provider cancellation is propagated")
    func cancellation() async throws {
        StubURLProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 2)
            return .init(data: Fixtures.data(Fixtures.openRouterStatusRSS200))
        }
        let cache = try temporaryCache(vendor: .openrouter)
        defer { remove(cache); StubURLProtocol.reset() }
        let provider = makeRSSProvider(descriptor: .openRouter, cache: cache)
        let task = Task<ServiceStatusOutcome, Error> {
            try await provider.fetchStatus(forceRefresh: true, now: fixtureNow)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch {
            expectTrue(error is CancellationError)
        }
    }

    @Test("factory adds secondary network sources while preserving input order")
    func factory_order() throws {
        let providers = try ServiceStatusProviderFactory.makeProviders(
            for: [.xai, .gemini, .anthropic, .deepseek, .openrouter, .zai],
            cacheTTL: 300
        )
        #expect(providers.map(\.vendorId) == [.xai, .anthropic, .deepseek, .openrouter])
        expectTrue(ServiceStatusProviderFactory.rssDescriptor(for: .openrouter) == .openRouter)
        expectTrue(ServiceStatusProviderFactory.rssDescriptor(for: .xai) == .xAI)
    }
}
