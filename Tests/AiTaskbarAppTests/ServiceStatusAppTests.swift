import Foundation
import Testing
import AiTaskbarCore
import AiTaskbarProviders
import AiTaskbarTestSupport
@testable import AiTaskbarApp

private actor StatusFetchProbe {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0

    func begin() {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func end() {
        active -= 1
    }
}

private struct StubStatusProvider: ServiceStatusProvider, Sendable {
    let vendorId: VendorId
    let fetch: @Sendable (Bool, Date) async throws -> ServiceStatusOutcome

    func fetchStatus(forceRefresh: Bool, now: Date) async throws -> ServiceStatusOutcome {
        try await fetch(forceRefresh, now)
    }
}

private actor StatusOutcomeSequence {
    private var call = 0
    let first: ServiceStatusOutcome

    init(first: ServiceStatusOutcome) { self.first = first }

    func next() throws -> ServiceStatusOutcome {
        call += 1
        if call == 1 { return first }
        throw AppError.transport("offline")
    }
}

@MainActor
@Suite("Service status app state and presentation", .serialized)
struct ServiceStatusAppTests {
    private func status(
        _ vendor: VendorId,
        level: ServiceStatusLevel = .operational,
        coverage: ServiceStatusCoverage = .full,
        summary: String = "Operational",
        incidents: [ServiceIncident] = []
    ) -> VendorServiceStatus {
        VendorServiceStatus(
            vendorId: vendor,
            level: level,
            coverage: coverage,
            summary: summary,
            sourceURL: vendor.statusPageURL,
            sourceUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            incidents: incidents
        )
    }

    private func outcome(
        _ vendor: VendorId,
        level: ServiceStatusLevel = .operational,
        coverage: ServiceStatusCoverage = .full,
        stale: Bool = false,
        fetchedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ServiceStatusOutcome {
        ServiceStatusOutcome(
            snapshot: status(vendor, level: level, coverage: coverage),
            isStale: stale,
            lastError: stale ? FetchError(status: 503, body: "maintenance") : nil,
            cacheAge: stale ? 60 : 0,
            fetchedAt: fetchedAt
        )
    }

    private func provider(
        _ vendor: VendorId,
        outcome: ServiceStatusOutcome,
        delay: Duration = .zero,
        probe: StatusFetchProbe? = nil
    ) -> StubStatusProvider {
        StubStatusProvider(vendorId: vendor) { _, _ in
            await probe?.begin()
            do {
                if delay != .zero { try await Task.sleep(for: delay) }
                await probe?.end()
                return outcome
            } catch {
                await probe?.end()
                throw error
            }
        }
    }

    @Test("one ordered row is retained per enabled vendor and link-only never requests")
    func ordered_rows_and_link_only() async {
        let unexpectedProbe = StatusFetchProbe()
        let unexpected = provider(.gemini, outcome: outcome(.gemini), probe: unexpectedProbe)
        let store = ServiceStatusStore(
            vendorIds: [.gemini, .zai, .gemini],
            providers: [unexpected]
        )

        store.refreshAll(forceRefresh: true)
        await store.waitForCurrentRefresh()

        #expect(store.rows.map(\.vendorId) == [.gemini, .zai])
        #expect(store.overallLevel == .unknown)
        #expect(!store.isLoading)
        let requestCount = await unexpectedProbe.calls
        #expect(requestCount == 0)
        for row in store.rows {
            guard case .unavailable(let snapshot) = row.state else {
                Issue.record("expected link-only unavailable row for \(row.vendorId)")
                continue
            }
            #expect(snapshot.coverage == .linkOnly)
            #expect(snapshot.level == .unknown)
        }
    }

    @Test("network sources refresh in parallel while results preserve row order")
    func parallel_refresh_preserves_order() async {
        let probe = StatusFetchProbe()
        let providers: [any ServiceStatusProvider] = [
            provider(.openai,
                     outcome: outcome(.openai, level: .partialOutage),
                     delay: .milliseconds(80),
                     probe: probe),
            provider(.anthropic,
                     outcome: outcome(.anthropic),
                     delay: .milliseconds(80),
                     probe: probe),
        ]
        let store = ServiceStatusStore(
            vendorIds: [.anthropic, .openai, .gemini],
            providers: providers
        )

        store.refreshAll(forceRefresh: true, now: Date(timeIntervalSince1970: 2_000))
        #expect(store.isLoading)
        await store.waitForCurrentRefresh()

        #expect(store.rows.map(\.vendorId) == [.anthropic, .openai, .gemini])
        #expect(store.overallLevel == .partialOutage)
        #expect(!store.isLoading)
        expectTrue(store.lastCompletedRefreshAt != nil)
        let maximumActive = await probe.maximumActive
        #expect(maximumActive == 2)
    }

    @Test("stale success remains visible and a later error preserves the previous result")
    func stale_and_error_preservation() async {
        let stale = outcome(.anthropic, level: .degradedPerformance, stale: true)
        let sequence = StatusOutcomeSequence(first: stale)
        let provider = StubStatusProvider(vendorId: .anthropic) { _, _ in
            try await sequence.next()
        }
        let store = ServiceStatusStore(vendorIds: [.anthropic], providers: [provider])

        store.refreshAll()
        await store.waitForCurrentRefresh()
        guard case .ok(let first) = store.rows[0].state else {
            Issue.record("expected stale success")
            return
        }
        #expect(first.isStale)

        store.refreshAll(forceRefresh: true)
        guard case .loading(let previous) = store.rows[0].state else {
            Issue.record("expected loading with previous")
            return
        }
        expectTrue(previous?.snapshot.level == .degradedPerformance)
        await store.waitForCurrentRefresh()
        guard case .failed(let error, let fallback) = store.rows[0].state else {
            Issue.record("expected failed state")
            return
        }
        #expect(error == .transport("offline"))
        expectTrue(fallback?.snapshot.level == .degradedPerformance)
        #expect(store.overallLevel == .degradedPerformance)
    }

    @Test("a superseded non-cooperative round cannot overwrite the latest epoch")
    func superseded_epoch_is_ignored() async {
        let oldNow = Date(timeIntervalSince1970: 1_000)
        let newNow = Date(timeIntervalSince1970: 2_000)
        let oldOutcome = outcome(.openai, level: .majorOutage)
        let newOutcome = outcome(.openai, level: .operational)
        let provider = StubStatusProvider(vendorId: .openai) { _, now in
            if now == oldNow {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { /* deliberately ignore cancellation */ }
                return oldOutcome
            }
            try await Task.sleep(for: .milliseconds(5))
            return newOutcome
        }
        let store = ServiceStatusStore(vendorIds: [.openai], providers: [provider])

        store.refreshAll(forceRefresh: true, now: oldNow)
        await Task.yield()
        store.refreshAll(forceRefresh: true, now: newNow)
        await store.waitForCurrentRefresh()
        try? await Task.sleep(for: .milliseconds(120))

        expectTrue(store.rows[0].state.outcome?.snapshot.level == .operational)
        #expect(store.overallLevel == .operational)
    }

    @Test("presentation maps every level to symbol, tone and localization key")
    func presentation_level_contract() {
        let expected: [(ServiceStatusLevel, String, ServiceStatusTone, String)] = [
            (.operational, "checkmark.circle.fill", .positive, "service_status_level_operational"),
            (.maintenance, "wrench.and.screwdriver.fill", .maintenance, "service_status_level_maintenance"),
            (.degradedPerformance, "exclamationmark.triangle.fill", .warning, "service_status_level_degraded"),
            (.partialOutage, "xmark.octagon.fill", .danger, "service_status_level_partial_outage"),
            (.majorOutage, "xmark.octagon.fill", .danger, "service_status_level_major_outage"),
            (.unknown, "questionmark.circle", .secondary, "service_status_level_unknown"),
        ]
        for (level, symbol, tone, key) in expected {
            #expect(ServiceStatusPresentation.symbol(for: level) == symbol)
            #expect(ServiceStatusPresentation.tone(for: level) == tone)
            #expect(ServiceStatusPresentation.levelKey(for: level) == key)
        }
    }

    @Test("coverage drives honest empty states")
    func coverage_empty_states() {
        #expect(ServiceStatusPresentation.emptyStateKey(for: .full)
                == "service_status_empty_full")
        #expect(ServiceStatusPresentation.emptyStateKey(for: .incidentsOnly)
                == "service_status_empty_incidents_only")
        #expect(ServiceStatusPresentation.emptyStateKey(for: .linkOnly)
                == "service_status_empty_link_only")
    }

    @Test("only allowlisted HTTPS status and incident links are presented")
    func safe_links() throws {
        let safe = try #require(URL(string: "https://status.openai.com/incidents/abc"))
        let badHost = try #require(URL(string: "https://example.com/phish"))
        let badScheme = try #require(URL(string: "http://status.openai.com/incidents/abc"))

        expectTrue(ServiceStatusPresentation.safeURL(safe, for: .openai) == safe)
        expectTrue(ServiceStatusPresentation.safeURL(badHost, for: .openai) == nil)
        expectTrue(ServiceStatusPresentation.safeURL(badScheme, for: .openai) == nil)
        expectTrue(ServiceStatusPresentation.safeURL(nil, for: .zai) == nil)
    }

    @Test("timeline clips incidents to six hours and summarizes duration by state")
    func timeline_and_accessibility_summary() {
        let now = Date(timeIntervalSince1970: 50_000)
        let incident = ServiceIncident(
            id: "long",
            title: "Long incident",
            level: .partialOutage,
            phase: .monitoring,
            startedAt: now.addingTimeInterval(-10 * 60 * 60),
            updatedAt: now,
            resolvedAt: now.addingTimeInterval(-3 * 60 * 60),
            affectedComponents: ["API"],
            message: "Monitoring",
            sourceURL: URL(string: "https://status.openai.com/incidents/long")
        )
        let snapshot = status(.openai, incidents: [incident])
        let segments = ServiceStatusPresentation.timelineSegments(for: snapshot, now: now)
        let incidentSegment = segments.first { $0.level == .partialOutage }

        expectTrue(incidentSegment?.startFraction == 0)
        expectTrue(incidentSegment?.endFraction == 0.5)
        expectTrue(ServiceStatusPresentation.durationByLevel(for: snapshot, now: now)[.partialOutage]
                   == 3 * 60 * 60)
    }

    @Test("every status localization key exists in English, Brazilian Portuguese and Spanish")
    func localization_completeness() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { repositoryRoot.deleteLastPathComponent() }
        let resources = repositoryRoot
            .appendingPathComponent("Sources/AiTaskbarApp/Resources")

        for language in ["en", "pt-BR", "es"] {
            let file = resources
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let contents = try String(contentsOf: file, encoding: .utf8)
            for key in ServiceStatusPresentation.localizationKeys {
                expectTrue(
                    contents.contains("\"\(key)\" = "),
                    "missing \(key) in \(language)"
                )
            }
        }
    }
}
