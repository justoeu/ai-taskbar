import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("Statuspage service-status provider", .serialized)
struct StatuspageProviderTests {
    init() {
        StubURLProtocol.reset()
    }

    private var fixtureNow: Date {
        ISO8601Parsing.parse("2026-09-03T12:00:00Z")!
    }

    private func temporaryCache(vendor: VendorId = .anthropic,
                                ttl: TimeInterval = 300) throws -> DiskCache {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-statuspage-\(UUID().uuidString)")
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

    private func installSuccessHandler(
        summary: String = Fixtures.statuspageSummaryOperational200,
        incidents: String = Fixtures.statuspageIncidentsWindow200,
        maintenances: String = Fixtures.statuspageMaintenancesWindow200
    ) {
        StubURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/v2/summary.json":
                return .init(data: Fixtures.data(summary))
            case "/api/v2/incidents.json":
                return .init(data: Fixtures.data(incidents))
            case "/api/v2/scheduled-maintenances.json":
                return .init(data: Fixtures.data(maintenances))
            default:
                return .init(status: 404, data: Data("missing".utf8))
            }
        }
    }

    private func makeProvider(
        descriptor: StatuspageDescriptor = .anthropic,
        cache: DiskCache,
        http: HTTPClient? = nil
    ) -> CachedServiceStatusProvider<StatuspageSource> {
        CachedServiceStatusProvider(
            source: StatuspageSource(descriptor: descriptor),
            cache: cache,
            http: http ?? HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        )
    }

    private func payload(
        summary fixture: String,
        incidents incidentFixture: String = #"{"incidents":[]}"#,
        maintenances maintenanceFixture: String = #"{"scheduled_maintenances":[]}"#
    ) throws -> StatuspageCachedPayload {
        StatuspageCachedPayload(
            summary: try JSONDecoder().decode(StatuspageSummary.self, from: Fixtures.data(fixture)),
            incidents: try JSONDecoder().decode(StatuspageIncidentList.self, from: Fixtures.data(incidentFixture)),
            scheduledMaintenances: try JSONDecoder().decode(StatuspageMaintenanceList.self, from: Fixtures.data(maintenanceFixture))
        )
    }

    @Test("descriptor presets pin vendors, hosts, and component metadata")
    func descriptor_presets() {
        #expect(StatuspageDescriptor.anthropic.vendorId == .anthropic)
        #expect(StatuspageDescriptor.anthropic.baseURL.absoluteString == "https://status.claude.com")
        expectTrue(StatuspageDescriptor.anthropic.components.map(\.id) == ["k8w3r06qmzrp", "yyzkbfz2thpt"])
        #expect(StatuspageDescriptor.openAI.vendorId == .openai)
        expectTrue(StatuspageDescriptor.openAI.baseURL.host == "status.openai.com")
        #expect(StatuspageDescriptor.openAI.components.map(\.name) == [
            "Codex Web", "Codex in ChatGPT Desktop", "Codex API", "Codex CLI", "VS Code extension",
        ])
        #expect(StatuspageDescriptor.kimi.vendorId == .kimi)
        expectTrue(StatuspageDescriptor.kimi.components.first?.id == "8psr5dfdld0s")
        expectTrue(ServiceStatusProviderFactory.descriptor(for: .openrouter) == nil)
        expectTrue(ServiceStatusProviderFactory.descriptor(for: .kimi) == .kimi)
    }

    @Test("Statuspage rejects excessive outer collections before rendering")
    func statuspage_collection_bounds() throws {
        let source = StatuspageSource(descriptor: .anthropic)
        let valid = try payload(summary: Fixtures.statuspageSummaryOperational200)
        let component = try #require(valid.summary.components.first)
        let oversizedSummary = StatuspageSummary(
            page: valid.summary.page,
            status: valid.summary.status,
            components: Array(repeating: component, count: 201),
            incidents: valid.summary.incidents,
            scheduledMaintenances: valid.summary.scheduledMaintenances
        )
        let oversized = StatuspageCachedPayload(
            summary: oversizedSummary,
            incidents: valid.incidents,
            scheduledMaintenances: valid.scheduledMaintenances
        )

        do {
            _ = try source.makeStatus(from: oversized, now: fixtureNow)
            Issue.record("expected Statuspage item limit")
        } catch let error as AppError {
            guard case .schema(let message) = error else {
                Issue.record("expected schema error, got \(error)")
                return
            }
            #expect(message.contains("item limit"))
        }
    }

    @Test("requests the three official HTTPS GET endpoints without auth")
    func requests_official_endpoints() async throws {
        installSuccessHandler()
        let cache = try temporaryCache()
        defer { remove(cache); StubURLProtocol.reset() }
        let provider = makeProvider(cache: cache)

        _ = try await provider.fetchStatus(forceRefresh: true, now: fixtureNow)

        let requests = StubURLProtocol.captured
        expectTrue(Set(requests.compactMap { $0.url?.absoluteString }) == Set([
            "https://status.claude.com/api/v2/summary.json",
            "https://status.claude.com/api/v2/incidents.json",
            "https://status.claude.com/api/v2/scheduled-maintenances.json",
        ]))
        expectTrue(Set(requests.compactMap(\.httpMethod)) == ["GET"])
        expectTrue(requests.compactMap {
            $0.value(forHTTPHeaderField: "Authorization")
        }.count == 0)
    }

    @Test("maps operational, maintenance, degraded, partial, major, and unknown tokens")
    func maps_status_levels() throws {
        let source = StatuspageSource(descriptor: .anthropic)
        let cases: [(String, ServiceStatusLevel)] = [
            (Fixtures.statuspageSummaryOperational200, .operational),
            (Fixtures.statuspageSummaryMaintenance200, .maintenance),
            (Fixtures.statuspageSummaryDegraded200, .degradedPerformance),
            (Fixtures.statuspageSummaryPartialOutage200, .partialOutage),
            (Fixtures.statuspageSummaryMajorOutage200, .majorOutage),
            (Fixtures.statuspageSummaryUnknown200, .unknown),
        ]

        for (fixture, expected) in cases {
            let status = try source.makeStatus(from: payload(summary: fixture), now: fixtureNow)
            #expect(status.level == expected)
        }
    }

    @Test("filters by component and six-hour intersection, preserves global incidents")
    func maps_window_and_components() throws {
        let source = StatuspageSource(descriptor: .anthropic)
        let combined = try payload(
            summary: Fixtures.statuspageSummaryDegraded200,
            incidents: Fixtures.statuspageIncidentsWindow200,
            maintenances: Fixtures.statuspageMaintenancesWindow200
        )

        let status = try source.makeStatus(from: combined, now: fixtureNow)

        #expect(status.vendorId == .anthropic)
        #expect(status.level == .degradedPerformance)
        #expect(status.coverage == .full)
        #expect(status.summary == "Minor Service Outage")
        expectTrue(status.sourceURL == URL(string: "https://status.claude.com"))
        expectTrue(status.sourceUpdatedAt == ISO8601Parsing.parse("2026-09-03T11:59:00Z"))
        #expect(status.incidents.map(\.id) == ["inc-active", "maint-active", "inc-global", "inc-long"])
        #expect(status.incidents[0].affectedComponents == ["Claude API", "Claude Code"])
        expectTrue(status.incidents[0].message == "A fix is deployed and recovery is being monitored.")
        #expect(status.incidents[0].phase == .monitoring)
        #expect(status.incidents[0].level == .degradedPerformance)
        #expect(status.incidents[1].phase == .inProgress)
        #expect(status.incidents[1].level == .maintenance)
        expectTrue(status.incidents[1].sourceURL == nil)
        #expect(status.incidents[2].affectedComponents == [])
        #expect(status.incidents[2].level == .majorOutage)
        expectTrue(status.incidents[3].resolvedAt == ISO8601Parsing.parse("2026-09-03T10:00:00Z"))
    }

    @Test("unknown incident tokens remain unknown instead of failing decode")
    func unknown_incident_tokens() throws {
        let source = StatuspageSource(descriptor: .anthropic)
        let combined = try payload(
            summary: Fixtures.statuspageSummaryOperational200,
            incidents: Fixtures.statuspageIncidentUnknownTokens200
        )
        let status = try source.makeStatus(from: combined, now: fixtureNow)

        #expect(status.incidents.count == 1)
        #expect(status.incidents[0].level == .unknown)
        #expect(status.incidents[0].phase == .unknown)
    }

    @Test("fresh cache skips network and force refresh bypasses it")
    func cache_fresh_and_force_refresh() async throws {
        installSuccessHandler()
        let cache = try temporaryCache(ttl: 60)
        defer { remove(cache); StubURLProtocol.reset() }
        let provider = makeProvider(cache: cache)

        _ = try await provider.fetchStatus(forceRefresh: true, now: fixtureNow)
        let firstCount = StubURLProtocol.captured.count
        let cached = try await provider.fetchStatus(forceRefresh: false, now: fixtureNow)
        #expect(StubURLProtocol.captured.count == firstCount)
        expectFalse(cached.isStale)

        _ = try await provider.fetchStatus(forceRefresh: true, now: fixtureNow)
        #expect(StubURLProtocol.captured.count == firstCount * 2)
    }

    @Test("503 returns stale cache but throws on cold cache")
    func server_error_stale_and_cold() async throws {
        installSuccessHandler()
        let warmCache = try temporaryCache(ttl: 0)
        defer { remove(warmCache); StubURLProtocol.reset() }
        let warmProvider = makeProvider(cache: warmCache)
        _ = try await warmProvider.fetchStatus(forceRefresh: true, now: fixtureNow)

        StubURLProtocol.handler = { _ in
            .init(status: 503, data: Data("temporarily unavailable".utf8))
        }
        let stale = try await warmProvider.fetchStatus(forceRefresh: true, now: fixtureNow)
        expectTrue(stale.isStale)
        expectTrue(stale.lastError?.status == 503)

        let coldCache = try temporaryCache(ttl: 0)
        defer { remove(coldCache) }
        let coldProvider = makeProvider(cache: coldCache)
        do {
            _ = try await coldProvider.fetchStatus(forceRefresh: true, now: fixtureNow)
            Issue.record("expected cold 503 to throw")
        } catch let error as AppError {
            guard case .http(let status, _) = error else {
                Issue.record("expected HTTP error, got \(error)")
                return
            }
            #expect(status == 503)
        }
    }

    @Test("invalid live timestamps do not replace a warm Statuspage cache")
    func invalid_live_timestamp_preserves_warm_cache() async throws {
        installSuccessHandler()
        let cache = try temporaryCache(ttl: 0)
        defer { remove(cache); StubURLProtocol.reset() }
        let provider = makeProvider(cache: cache)
        let warm = try await provider.fetchStatus(forceRefresh: true, now: fixtureNow)
        let cachedBytes = try #require(cache.anyPayload())

        let invalidSummary = Fixtures.statuspageSummaryOperational200.replacingOccurrences(
            of: "2026-09-03T11:59:00.000Z",
            with: "not-a-date"
        )
        installSuccessHandler(summary: invalidSummary)
        let stale = try await provider.fetchStatus(forceRefresh: true, now: fixtureNow)

        #expect(stale.snapshot == warm.snapshot)
        #expect(stale.isStale)
        #expect(cache.anyPayload() == cachedBytes)
    }

    @Test("invalid schema on a cold cache surfaces AppError.schema")
    func schema_failure() async throws {
        StubURLProtocol.handler = { _ in .init(data: Data("{}".utf8)) }
        let cache = try temporaryCache()
        defer { remove(cache); StubURLProtocol.reset() }
        let provider = makeProvider(cache: cache)

        do {
            _ = try await provider.fetchStatus(forceRefresh: true, now: fixtureNow)
            Issue.record("expected schema failure")
        } catch let error as AppError {
            guard case .schema = error else {
                Issue.record("expected schema error, got \(error)")
                return
            }
        }
    }

    @Test("each response is capped at two MiB")
    func payload_limit() async throws {
        let oversized = Fixtures.data(Fixtures.statuspageSummaryOperational200)
            + Data(repeating: 0x20, count: 2 * 1024 * 1024)
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/v2/summary.json" {
                return .init(data: oversized)
            }
            if request.url?.path == "/api/v2/incidents.json" {
                return .init(data: Data(#"{"incidents":[]}"#.utf8))
            }
            return .init(data: Data(#"{"scheduled_maintenances":[]}"#.utf8))
        }
        let cache = try temporaryCache()
        defer { remove(cache); StubURLProtocol.reset() }
        let provider = makeProvider(cache: cache)

        do {
            _ = try await provider.fetchStatus(forceRefresh: true, now: fixtureNow)
            Issue.record("expected oversized response to fail")
        } catch let error as AppError {
            guard case .transport(let message) = error else {
                Issue.record("expected transport error, got \(error)")
                return
            }
            expectTrue(message.contains("2097152"))
        }
    }

    @Test("rejects non-HTTPS and wrong-host descriptors before network")
    func validates_exact_https_host() async throws {
        let invalid = [
            StatuspageDescriptor(vendorId: .anthropic,
                                 baseURL: URL(string: "http://status.claude.com")!,
                                 components: []),
            StatuspageDescriptor(vendorId: .anthropic,
                                 baseURL: URL(string: "https://evil.example")!,
                                 components: []),
        ]
        for descriptor in invalid {
            StubURLProtocol.reset()
            StubURLProtocol.handler = { _ in
                Issue.record("invalid descriptor must not perform network I/O")
                return .init(data: Data())
            }
            let cache = try temporaryCache()
            defer { remove(cache) }
            let provider = makeProvider(descriptor: descriptor, cache: cache)
            do {
                _ = try await provider.fetchStatus(forceRefresh: true, now: fixtureNow)
                Issue.record("expected descriptor validation failure")
            } catch let error as AppError {
                guard case .schema = error else {
                    Issue.record("expected schema error, got \(error)")
                    continue
                }
            }
            #expect(StubURLProtocol.captured.count == 0)
        }
        StubURLProtocol.reset()
    }

    @Test("OpenAI tolerates its official maintenance endpoint returning 404")
    func openai_missing_maintenance_endpoint() async throws {
        StubURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/v2/summary.json":
                return .init(data: Fixtures.data(Fixtures.statuspageSummaryOperational200))
            case "/api/v2/incidents.json":
                return .init(data: Data(#"{"incidents":[]}"#.utf8))
            default:
                return .init(status: 404, data: Data("not found".utf8))
            }
        }
        let cache = try temporaryCache(vendor: .openai)
        defer { remove(cache); StubURLProtocol.reset() }
        let provider = makeProvider(descriptor: .openAI, cache: cache)

        let outcome = try await provider.fetchStatus(forceRefresh: true, now: fixtureNow)
        #expect(outcome.snapshot.vendorId == .openai)
        #expect(outcome.snapshot.incidents.count == 0)
    }

    @Test("task cancellation is propagated")
    func cancellation() async throws {
        StubURLProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 5)
            return .init(data: Data("{}".utf8))
        }
        let cache = try temporaryCache()
        defer { remove(cache); StubURLProtocol.reset() }
        let provider = makeProvider(cache: cache)
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
}
