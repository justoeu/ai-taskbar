import Testing
import Foundation
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// Field-by-field contract tests for every Statuspage v2 wire struct. These
/// values are intentionally frozen inline so schema changes are explicit.
@Suite("Statuspage v2 wire goldens")
struct StatuspageGoldenTests {
    @Test("summary, page, status, and component fields are frozen")
    func summary_wire_golden() throws {
        let summary = try JSONDecoder().decode(
            StatuspageSummary.self,
            from: Fixtures.data(Fixtures.statuspageSummaryOperational200)
        )

        #expect(summary.page.id == "page-claude")
        #expect(summary.page.name == "Claude")
        expectTrue(summary.page.url == "https://status.claude.com")
        expectTrue(summary.page.timeZone == "Etc/UTC")
        expectTrue(summary.page.updatedAt == "2026-09-03T11:59:00.000Z")
        #expect(summary.status.indicator == "none")
        #expect(summary.status.description == "All Systems Operational")
        #expect(summary.components.count == 3)

        let component = summary.components[1]
        #expect(component.id == "yyzkbfz2thpt")
        #expect(component.name == "Claude Code")
        #expect(component.status == "operational")
        expectTrue(component.createdAt == "2025-05-22T21:35:29.822Z")
        expectTrue(component.updatedAt == "2026-09-03T11:57:00.000Z")
        expectTrue(component.position == 4)
        expectTrue(component.description == "Command-line and IDE clients")
        expectTrue(component.groupID == nil)
        #expect(summary.incidents.count == 0)
        #expect(summary.scheduledMaintenances.count == 0)
    }

    @Test("incident, update, and affected-component fields are frozen")
    func incident_wire_golden() throws {
        let list = try JSONDecoder().decode(
            StatuspageIncidentList.self,
            from: Fixtures.data(Fixtures.statuspageIncidentsWindow200)
        )

        let page = try #require(list.page)
        #expect(page.id == "page-claude")
        #expect(list.incidents.count == 6)
        let incident = list.incidents[0]
        #expect(incident.id == "inc-active")
        #expect(incident.name == "Elevated API errors")
        #expect(incident.status == "monitoring")
        #expect(incident.impact == "minor")
        #expect(incident.createdAt == "2026-09-03T10:00:00Z")
        #expect(incident.updatedAt == "2026-09-03T11:50:00Z")
        expectTrue(incident.startedAt == "2026-09-03T10:00:00Z")
        expectTrue(incident.resolvedAt == nil)
        expectTrue(incident.shortlink == "https://status.claude.com/incidents/inc-active")
        expectTrue(incident.scheduledFor == nil)
        expectTrue(incident.scheduledUntil == nil)
        let components = try #require(incident.components)
        #expect(components.count == 2)
        #expect(incident.incidentUpdates.count == 1)

        let update = incident.incidentUpdates[0]
        #expect(update.id == "update-active")
        #expect(update.status == "monitoring")
        expectTrue(update.body == "A fix is deployed and recovery is being monitored.")
        expectTrue(update.incidentID == "inc-active")
        expectTrue(update.createdAt == "2026-09-03T11:50:00Z")
        expectTrue(update.updatedAt == "2026-09-03T11:50:00Z")
        expectTrue(update.displayAt == "2026-09-03T11:50:00Z")
        let affectedComponents = try #require(update.affectedComponents)
        #expect(affectedComponents.count == 2)

        let affected = affectedComponents[0]
        #expect(affected.code == "k8w3r06qmzrp")
        #expect(affected.name == "Claude API")
        expectTrue(affected.oldStatus == "partial_outage")
        expectTrue(affected.newStatus == "degraded_performance")
    }

    @Test("scheduled-maintenance fields are frozen")
    func maintenance_wire_golden() throws {
        let list = try JSONDecoder().decode(
            StatuspageMaintenanceList.self,
            from: Fixtures.data(Fixtures.statuspageMaintenancesWindow200)
        )

        let page = try #require(list.page)
        #expect(page.name == "Claude")
        #expect(list.scheduledMaintenances.count == 1)
        let maintenance = list.scheduledMaintenances[0]
        #expect(maintenance.id == "maint-active")
        #expect(maintenance.name == "API database maintenance")
        #expect(maintenance.status == "in_progress")
        #expect(maintenance.impact == "maintenance")
        #expect(maintenance.createdAt == "2026-09-03T08:30:00Z")
        #expect(maintenance.updatedAt == "2026-09-03T11:40:00Z")
        expectTrue(maintenance.startedAt == "2026-09-03T09:00:00Z")
        expectTrue(maintenance.resolvedAt == nil)
        expectTrue(maintenance.shortlink == "https://attacker.example/redirect")
        expectTrue(maintenance.scheduledFor == "2026-09-03T09:00:00Z")
        expectTrue(maintenance.scheduledUntil == "2026-09-03T13:00:00Z")
        let component = try #require(maintenance.components?.first)
        #expect(component.id == "k8w3r06qmzrp")
        let update = try #require(maintenance.incidentUpdates.first)
        #expect(update.status == "in_progress")
    }

    @Test("combined cached payload is Codable and field-stable")
    func combined_payload_golden() throws {
        let summary = try JSONDecoder().decode(
            StatuspageSummary.self,
            from: Fixtures.data(Fixtures.statuspageSummaryOperational200)
        )
        let incidents = try JSONDecoder().decode(
            StatuspageIncidentList.self,
            from: Fixtures.data(Fixtures.statuspageIncidentsWindow200)
        )
        let maintenances = try JSONDecoder().decode(
            StatuspageMaintenanceList.self,
            from: Fixtures.data(Fixtures.statuspageMaintenancesWindow200)
        )
        let payload = StatuspageCachedPayload(
            summary: summary,
            incidents: incidents,
            scheduledMaintenances: maintenances
        )
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(StatuspageCachedPayload.self, from: encoded)

        #expect(decoded.summary.page.id == "page-claude")
        #expect(decoded.incidents.incidents.count == 6)
        #expect(decoded.scheduledMaintenances.scheduledMaintenances.count == 1)
        #expect(decoded == payload)
    }
}
