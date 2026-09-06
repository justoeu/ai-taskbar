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
    private(set) var beganAt: [Date] = []
    private(set) var endedAt: [Date] = []

    func begin() {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        beganAt.append(.now)
    }

    func end() {
        active -= 1
        endedAt.append(.now)
    }

    func firstCompletionToNextStartGap() -> TimeInterval? {
        guard let firstEnd = endedAt.first, beganAt.count > 1 else { return nil }
        return beganAt[1].timeIntervalSince(firstEnd)
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
        fetchedAt: Date = .now
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

    @Test("only enabled vendors with official status pages retain ordered rows")
    func ordered_rows_and_link_only() async {
        let unexpectedProbe = StatusFetchProbe()
        let unexpected = provider(.gemini, outcome: outcome(.gemini), probe: unexpectedProbe)
        let store = ServiceStatusStore(
            vendorIds: [.gemini, .zai, .gemini],
            providers: [unexpected]
        )

        store.refreshAll(forceRefresh: true)
        await store.waitForCurrentRefresh()

        #expect(store.rows.map(\.vendorId) == [.gemini])
        #expect(store.overallLevel == .unknown)
        #expect(!store.isLoading)
        #expect(!store.hasAutomaticSources)
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

    @Test("OpenRouter uses its official public status page")
    func openrouter_status_page_url() throws {
        let expected = try #require(URL(string: "https://status.openrouter.ai/"))

        expectTrue(VendorId.openrouter.statusPageURL == expected)
        expectTrue(RSSStatusDescriptor.openRouter.statusPageURL == expected)
    }

    @Test("status scheduler sleeps after a completed round before polling again")
    func scheduler_cadence_is_anchored_after_completion() async throws {
        let probe = StatusFetchProbe()
        let statusStore = ServiceStatusStore(
            vendorIds: [.anthropic],
            providers: [provider(
                .anthropic,
                outcome: outcome(.anthropic),
                delay: .milliseconds(80),
                probe: probe
            )]
        )
        let usageStore = UsageStore(vendors: [], primary: nil)
        let scheduler = RefreshScheduler(
            store: usageStore,
            statusStore: statusStore,
            interval: 0.04,
            minimumInterval: 0,
            minimumStatusInterval: 0
        )
        scheduler.start()
        for _ in 0..<200 {
            if await probe.calls >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        scheduler.stop()

        let gap = try #require(await probe.firstCompletionToNextStartGap())
        #expect(gap >= 0.03)
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

    @Test("unverified operational status stays unknown through repeated refreshes", arguments: [0, 1, 2])
    func unverified_operational_does_not_turn_green(mode: Int) async {
        let first = ServiceStatusOutcome(
            snapshot: status(.anthropic),
            isStale: mode == 0,
            lastError: mode == 2 ? FetchError(status: 503, body: "offline") : nil
        )
        let sequence = StatusOutcomeSequence(first: first)
        let source = StubStatusProvider(vendorId: .anthropic) { _, _ in
            try await sequence.next()
        }
        let store = ServiceStatusStore(vendorIds: [.anthropic], providers: [source])
        store.refreshAll()
        await store.waitForCurrentRefresh()
        if mode == 1 {
            store.refreshAll(forceRefresh: true)
            await store.waitForCurrentRefresh()
        }
        #expect(store.overallLevel == .unknown)
        #expect(store.rows[0].state.isStale)

        // Assert synchronously before either new task can complete, including
        // superseding an already-loading round with the same old snapshot.
        for _ in 0..<2 {
            store.refreshAll(forceRefresh: true)
            #expect(store.isLoading)
            #expect(store.rows[0].state.isStale)
            #expect(store.overallLevel == .unknown)
        }
        await store.waitForCurrentRefresh()
        #expect(store.overallLevel == .unknown)
    }

    @Test("in-memory status fallback respects the six-hour retention limit", arguments: [-6.0, 0, 21_600, 21_601])
    func in_memory_fallback_expires(age: TimeInterval) async {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sequence = StatusOutcomeSequence(first: outcome(
            .anthropic, level: .majorOutage, stale: true, fetchedAt: fetchedAt
        ))
        let source = StubStatusProvider(vendorId: .anthropic) { _, _ in
            try await sequence.next()
        }
        let store = ServiceStatusStore(vendorIds: [.anthropic], providers: [source])
        store.refreshAll(now: fetchedAt)
        await store.waitForCurrentRefresh()
        let retainsFallback = age >= -5 && age <= ServiceStatusWindow.duration

        store.refreshAll(now: fetchedAt.addingTimeInterval(age))
        expectTrue((store.rows[0].state.outcome != nil) == retainsFallback)
        #expect(store.overallLevel == (retainsFallback ? .majorOutage : .unknown))
        await store.waitForCurrentRefresh()
        expectTrue((store.rows[0].state.outcome != nil) == retainsFallback)
        #expect(store.overallLevel == (retainsFallback ? .majorOutage : .unknown))
    }

    @Test("stale status presentation never claims operational health", arguments: [false, true])
    func stale_display_status(hasErrorMarker: Bool) throws {
        let raw = ServiceStatusOutcome(
            snapshot: status(.anthropic),
            isStale: !hasErrorMarker,
            lastError: hasErrorMarker ? FetchError(status: 503, body: "offline") : nil
        )
        let state = ServiceStatusStore.Row.State.ok(raw)
        let display = try #require(state.displayStatus)
        #expect(display.level == .unknown)
        #expect(ServiceStatusPresentation.symbol(for: display.level) == "circle.dashed")
        #expect(ServiceStatusPresentation.displayLevelKey(for: display, hasObservation: true)
                == "service_status_level_unknown")
        #expect(ServiceStatusPresentation.timelineSegments(for: display, now: .now).map(\.level)
                == [.unknown])
        // Presentation must not rewrite the original provider snapshot.
        expectTrue(state.status?.level == .operational)
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

    @Test("stale operational data stays visible but cannot make the aggregate green")
    func stale_operational_is_unknown_in_aggregate() async {
        let stale = outcome(.anthropic, level: .operational, stale: true)
        let provider = StubStatusProvider(vendorId: .anthropic) { _, _ in stale }
        let store = ServiceStatusStore(vendorIds: [.anthropic], providers: [provider])

        store.refreshAll()
        await store.waitForCurrentRefresh()

        expectTrue(store.rows[0].state.outcome?.snapshot.level == .operational)
        #expect(store.overallLevel == .unknown)
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
            (.unknown, "circle.dashed", .secondary, "service_status_level_unknown"),
        ]
        for (level, symbol, tone, key) in expected {
            #expect(ServiceStatusPresentation.symbol(for: level) == symbol)
            #expect(ServiceStatusPresentation.tone(for: level) == tone)
            #expect(ServiceStatusPresentation.levelKey(for: level) == key)
        }
        #expect(ServiceStatusPresentation.headerSymbol == "waveform.path.ecg")
        #expect(ServiceStatusPresentation.expectedCoverage(for: .xai) == .incidentsOnly)
        #expect(ServiceStatusPresentation.displayLevelKey(
            for: status(.xai, level: .unknown, coverage: .incidentsOnly),
            hasObservation: true
        ) == "service_status_level_no_active_incidents")
        #expect(ServiceStatusPresentation.displayLevelKey(
            for: status(.xai, level: .unknown, coverage: .incidentsOnly),
            hasObservation: false
        ) == "service_status_level_unknown")
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

    @Test("timeline resolves overlapping incidents to non-overlapping worst-level segments")
    func timeline_overlap_uses_worst_level() {
        let now = Date(timeIntervalSince1970: 21_600)
        let outage = ServiceIncident(
            id: "outage", title: "Outage", level: .majorOutage,
            phase: .monitoring, startedAt: now.addingTimeInterval(-4.5 * 3_600),
            updatedAt: now, resolvedAt: now.addingTimeInterval(-1.5 * 3_600),
            affectedComponents: [], message: nil, sourceURL: nil
        )
        let maintenance = ServiceIncident(
            id: "maintenance", title: "Maintenance", level: .maintenance,
            phase: .inProgress, startedAt: now.addingTimeInterval(-3 * 3_600),
            updatedAt: now.addingTimeInterval(-60), resolvedAt: nil,
            affectedComponents: [], message: nil, sourceURL: nil
        )
        let snapshot = status(.openai, incidents: [outage, maintenance])

        let segments = ServiceStatusPresentation.timelineSegments(for: snapshot, now: now)

        #expect(segments == [
            ServiceStatusTimelineSegment(level: .operational, startFraction: 0, endFraction: 0.25),
            ServiceStatusTimelineSegment(level: .majorOutage, startFraction: 0.25, endFraction: 0.75),
            ServiceStatusTimelineSegment(level: .maintenance, startFraction: 0.75, endFraction: 1),
        ])
    }

    @Test("full coverage with unknown current state never paints a green timeline")
    func unknown_full_status_has_unknown_timeline() {
        let now = Date(timeIntervalSince1970: 21_600)
        let snapshot = status(.openai, level: .unknown, coverage: .full)

        let segments = ServiceStatusPresentation.timelineSegments(for: snapshot, now: now)

        #expect(segments == [
            ServiceStatusTimelineSegment(level: .unknown, startFraction: 0, endFraction: 1),
        ])
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
