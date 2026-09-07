import Foundation
import Testing
@testable import AiTaskbarCore

@Suite("Service status domain")
struct ServiceStatusTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func incident(
        id: String,
        level: ServiceStatusLevel = .degradedPerformance,
        phase: ServiceIncidentPhase = .investigating,
        startedAt: Date,
        updatedAt: Date? = nil,
        resolvedAt: Date? = nil
    ) -> ServiceIncident {
        ServiceIncident(
            id: id,
            title: "Incident \(id)",
            level: level,
            phase: phase,
            startedAt: startedAt,
            updatedAt: updatedAt ?? startedAt,
            resolvedAt: resolvedAt,
            affectedComponents: ["API"],
            message: "Investigating",
            sourceURL: URL(string: "https://status.example.com/incidents/\(id)")
        )
    }

    @Test("six-hour window includes closed boundaries and long-running incidents")
    func intersection_boundaries_and_long_incident() {
        let cutoff = now.addingTimeInterval(-ServiceStatusWindow.duration)
        let startsAtNow = incident(id: "now", startedAt: now, resolvedAt: now)
        let resolvesAtCutoff = incident(
            id: "cutoff",
            startedAt: cutoff.addingTimeInterval(-3_600),
            resolvedAt: cutoff
        )
        let longRunning = incident(
            id: "long",
            startedAt: cutoff.addingTimeInterval(-14_400)
        )

        expectTrue(ServiceStatusWindow.intersects(startsAtNow, now: now))
        expectTrue(ServiceStatusWindow.intersects(resolvesAtCutoff, now: now))
        expectTrue(ServiceStatusWindow.intersects(longRunning, now: now))
    }

    @Test("six-hour window rejects future and fully old incidents")
    func intersection_rejects_future_and_old() {
        let cutoff = now.addingTimeInterval(-ServiceStatusWindow.duration)
        let future = incident(id: "future", startedAt: now.addingTimeInterval(1))
        let old = incident(
            id: "old",
            startedAt: cutoff.addingTimeInterval(-7_200),
            resolvedAt: cutoff.addingTimeInterval(-1)
        )

        expectFalse(ServiceStatusWindow.intersects(future, now: now))
        expectFalse(ServiceStatusWindow.intersects(old, now: now))
    }

    @Test("clipped range stays inside the six-hour window")
    func clipped_range_stays_inside_window() {
        let cutoff = now.addingTimeInterval(-ServiceStatusWindow.duration)
        let longRunning = incident(
            id: "long",
            startedAt: cutoff.addingTimeInterval(-3_600)
        )
        let clipped = ServiceStatusWindow.clippedRange(for: longRunning, now: now)

        expectTrue(clipped?.lowerBound == cutoff)
        expectTrue(clipped?.upperBound == now)
    }

    @Test("recent incidents filter then sort by updatedAt descending and id")
    func recent_incidents_are_filtered_and_sorted() {
        let cutoff = now.addingTimeInterval(-ServiceStatusWindow.duration)
        let newestB = incident(
            id: "b",
            startedAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-10)
        )
        let newestA = incident(
            id: "a",
            startedAt: now.addingTimeInterval(-200),
            updatedAt: now.addingTimeInterval(-10)
        )
        let older = incident(
            id: "older",
            startedAt: now.addingTimeInterval(-300),
            updatedAt: now.addingTimeInterval(-20)
        )
        let outside = incident(
            id: "outside",
            startedAt: cutoff.addingTimeInterval(-300),
            resolvedAt: cutoff.addingTimeInterval(-1)
        )

        let result = ServiceStatusWindow.recentIncidents(
            [older, outside, newestB, newestA],
            now: now
        )

        #expect(result.map(\.id) == ["a", "b", "older"])
    }

    @Test("worst level honors precedence and unknown blocks green")
    func worst_level_precedence_and_unknown() {
        #expect(ServiceStatusWindow.worstLevel(in: []) == .unknown)
        #expect(ServiceStatusWindow.worstLevel(in: [.operational]) == .operational)
        #expect(ServiceStatusWindow.worstLevel(in: [.operational, .unknown]) == .unknown)
        #expect(ServiceStatusWindow.worstLevel(in: [.unknown, .maintenance]) == .maintenance)
        #expect(ServiceStatusWindow.worstLevel(in: [.maintenance, .degradedPerformance]) == .degradedPerformance)
        #expect(ServiceStatusWindow.worstLevel(in: [.partialOutage, .majorOutage]) == .majorOutage)
    }

    @Test("non-full coverage cannot make the aggregate operational")
    func non_full_coverage_cannot_make_aggregate_operational() {
        let full = VendorServiceStatus(
            vendorId: .anthropic,
            level: .operational,
            coverage: .full,
            summary: "Operational",
            sourceURL: URL(string: "https://status.claude.com"),
            sourceUpdatedAt: now,
            incidents: []
        )
        let incidentsOnly = VendorServiceStatus(
            vendorId: .openrouter,
            level: .operational,
            coverage: .incidentsOnly,
            summary: "No active incidents",
            sourceURL: URL(string: "https://status.openrouter.ai"),
            sourceUpdatedAt: now,
            incidents: []
        )

        #expect(ServiceStatusWindow.overallLevel(for: [full, incidentsOnly]) == .unknown)
    }

    @Test("service status models are Codable and Equatable")
    func codable_round_trip() throws {
        let value = VendorServiceStatus(
            vendorId: .anthropic,
            level: .partialOutage,
            coverage: .full,
            summary: "Partial outage",
            sourceURL: URL(string: "https://status.claude.com"),
            sourceUpdatedAt: now,
            incidents: [incident(
                id: "incident-1",
                level: .partialOutage,
                phase: .monitoring,
                startedAt: now.addingTimeInterval(-1_800),
                updatedAt: now.addingTimeInterval(-300),
                resolvedAt: now.addingTimeInterval(-60)
            )]
        )

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(VendorServiceStatus.self, from: data)

        #expect(decoded == value)
    }

    @Test("vendor status-page URLs are fixed official HTTPS links")
    func vendor_status_page_urls() {
        expectTrue(VendorId.anthropic.statusPageURL?.host == "status.claude.com")
        expectTrue(VendorId.openai.statusPageURL?.host == "status.openai.com")
        expectTrue(VendorId.kimi.statusPageURL?.host == "status.moonshot.cn")
        expectTrue(VendorId.deepseek.statusPageURL?.host == "status.deepseek.com")
        expectTrue(VendorId.openrouter.statusPageURL?.host == "status.openrouter.ai")
        expectTrue(VendorId.xai.statusPageURL?.host == "status.x.ai")
        expectTrue(VendorId.gemini.statusPageURL?.host == "aistudio.google.com")
        expectTrue(VendorId.zai.statusPageURL == nil)
    }
}
