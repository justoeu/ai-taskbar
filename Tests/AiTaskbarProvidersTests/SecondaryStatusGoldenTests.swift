import Testing
import Foundation
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// Field-by-field contracts for every FlashDuty and RSS wire struct. Frozen
/// values stay inline so upstream schema decisions remain review-visible.
@Suite("Secondary service-status wire goldens")
struct SecondaryStatusGoldenTests {
    @Test("DeepSeek active summary, page, component, section, and change fields are frozen")
    func deepseek_active_golden() throws {
        let envelope = try JSONDecoder().decode(
            DeepSeekStatusEnvelope<DeepSeekActiveStatus>.self,
            from: Fixtures.data(Fixtures.deepseekStatusActive200)
        )

        #expect(envelope.requestID == "request-active")
        #expect(envelope.data.page.pageID == 6_410_630_422_455)
        #expect(envelope.data.page.name == "DeepSeek")
        #expect(envelope.data.page.urlName == "deepseek")
        #expect(envelope.data.page.type == "public")
        #expect(envelope.data.page.customDomain == "status.deepseek.com")
        expectTrue(envelope.data.page.logo == "https://static.flashcat.cloud/deepseek-logo.png")
        expectTrue(envelope.data.page.logoURL == "https://www.deepseek.com/")
        expectTrue(envelope.data.page.dateView == "calendar")
        expectTrue(envelope.data.page.displayUptimeMode == "chart_and_percentage")
        #expect(envelope.data.page.components.count == 2)
        #expect(envelope.data.page.sections.count == 1)

        let component = envelope.data.page.components[0]
        #expect(component.componentID == "api-service")
        expectTrue(component.sectionID == nil)
        #expect(component.name == "API Service")
        expectTrue(component.description == "DeepSeek API availability")
        #expect(component.availableSinceSeconds == 1_706_745_600)
        #expect(component.orderID == 1)
        expectTrue(component.status == nil)

        let section = envelope.data.page.sections[0]
        #expect(section.sectionID == "chat-section")
        #expect(section.name == "Chat")
        expectTrue(section.description == "DeepSeek chat availability")
        #expect(section.orderID == 1)
        expectFalse(section.hideUptime)
        expectFalse(section.hideAll)

        #expect(envelope.data.activeChanges.count == 1)
        let change = envelope.data.activeChanges[0]
        #expect(change.changeID == 7001)
        #expect(change.pageID == 6_410_630_422_455)
        #expect(change.type == "incident")
        #expect(change.title == "API partially unavailable")
        expectTrue(change.description == "We are monitoring recovery.")
        #expect(change.status == "monitoring")
        #expect(change.startAtSeconds == 1_788_433_200)
        expectTrue(change.closeAtSeconds == nil)
        expectTrue(change.notifySubscribers)
        #expect(change.affectedComponents.count == 1)
        expectTrue(change.affectedComponents[0].status == "partial_outage")
        #expect(change.updates.count == 2)

        let update = change.updates[1]
        #expect(update.updateID == "update-monitoring")
        #expect(update.atSeconds == 1_788_436_200)
        #expect(update.status == "monitoring")
        expectTrue(update.description == "A fix is deployed; monitoring recovery.")
        #expect(update.componentChanges.count == 1)
        let componentChange = update.componentChanges[0]
        #expect(componentChange.componentID == "api-service")
        #expect(componentChange.componentName == "API Service")
        #expect(componentChange.status == "partial_outage")
    }

    @Test("DeepSeek structure impact, uptime, and linked-change fields are frozen")
    func deepseek_structure_golden() throws {
        let envelope = try JSONDecoder().decode(
            DeepSeekStatusEnvelope<DeepSeekStatusStructure>.self,
            from: Fixtures.data(Fixtures.deepseekStatusStructure200)
        )

        #expect(envelope.requestID == "request-structure")
        #expect(envelope.data.sectionImpacts.count == 1)
        #expect(envelope.data.componentImpacts.count == 1)
        let impact = envelope.data.componentImpacts[0]
        expectTrue(impact.componentID == "api-service")
        expectTrue(impact.sectionID == "")
        #expect(impact.changeID == 7001)
        #expect(impact.startAtSeconds == 1_788_433_200)
        #expect(impact.endAtSeconds == 1_788_436_800)
        #expect(impact.status == "partial_outage")

        #expect(envelope.data.sectionUptimes.count == 1)
        #expect(envelope.data.componentUptimes.count == 1)
        let uptime = envelope.data.componentUptimes[0]
        expectTrue(uptime.componentID == "api-service")
        expectTrue(uptime.sectionID == "")
        #expect(uptime.uptime == 94.25)
        #expect(uptime.availableSinceSeconds == 1_706_745_600)

        #expect(envelope.data.linkedChanges.count == 1)
        let linked = envelope.data.linkedChanges[0]
        #expect(linked.id == 7001)
        #expect(linked.type == "incident")
        #expect(linked.title == "API partially unavailable")
    }

    @Test("DeepSeek change-list envelope and Codable cache payload are frozen")
    func deepseek_change_list_golden() throws {
        let changes = try JSONDecoder().decode(
            DeepSeekStatusEnvelope<DeepSeekChangeList>.self,
            from: Fixtures.data(Fixtures.deepseekStatusChanges200)
        )
        #expect(changes.requestID == "request-changes")
        #expect(changes.data.items.count == 4)
        expectTrue(changes.data.items[1].closeAtSeconds == 1_788_429_600)

        let active = try JSONDecoder().decode(
            DeepSeekStatusEnvelope<DeepSeekActiveStatus>.self,
            from: Fixtures.data(Fixtures.deepseekStatusActive200)
        )
        let structure = try JSONDecoder().decode(
            DeepSeekStatusEnvelope<DeepSeekStatusStructure>.self,
            from: Fixtures.data(Fixtures.deepseekStatusStructure200)
        )
        let payload = DeepSeekStatusPayload(
            active: active,
            structure: structure,
            changes: changes
        )
        let decoded = try JSONDecoder().decode(
            DeepSeekStatusPayload.self,
            from: JSONEncoder().encode(payload)
        )
        #expect(decoded.active.requestID == "request-active")
        #expect(decoded.structure.data.componentImpacts.count == 1)
        #expect(decoded.changes.data.items.count == 4)
        #expect(decoded == payload)
    }

    @Test("RSS channel, item, GUID attribute, category, and cache fields are frozen")
    func rss_wire_golden() throws {
        let feed = try RSSStatusSource.parse(
            Fixtures.data(Fixtures.openRouterStatusRSS200)
        )

        #expect(feed.title == "OpenRouter Status - Incident History")
        expectTrue(feed.link == "status.openrouter.ai")
        expectTrue(feed.description == "Statuspage")
        expectTrue(feed.lastBuildDate == "Thu, 03 Sep 2026 11:55:00 GMT")
        #expect(feed.items.count == 6)
        let item = feed.items[0]
        #expect(item.title == "API & routing degraded")
        expectTrue(item.description?.contains("<strong>MONITORING</strong>") == true)
        #expect(item.pubDate == "Thu, 03 Sep 2026 11:00:00 GMT")
        expectTrue(item.link == "status.openrouter.ai/incidents/incident-active")
        expectTrue(item.guid == "status.openrouter.ai/incidents/incident-active")
        expectTrue(item.guidIsPermaLink == true)
        #expect(item.categories == ["degraded_performance", "monitoring"])

        let decoded = try JSONDecoder().decode(
            RSSStatusFeed.self,
            from: JSONEncoder().encode(feed)
        )
        #expect(decoded.title == feed.title)
        #expect(decoded.items.count == 6)
        #expect(decoded == feed)
    }
}
