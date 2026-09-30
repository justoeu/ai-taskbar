import Testing
import Foundation
@testable import AiTaskbarApp
import AiTaskbarCore

@Suite("VendorOrder.moved")
struct VendorOrderMovedTests {
    let visible: [VendorId] = [.anthropic, .openai, .xai]

    @Test("moves one step and appends unknown visible vendors in visible order")
    func moves_and_appends() {
        #expect(VendorOrder.moved(.openai, up: true, order: [], visible: visible) == [.openai, .anthropic, .xai])
        #expect(VendorOrder.moved(.openai, up: false, order: [], visible: visible) == [.anthropic, .xai, .openai])
        // A partial stored order is completed with the missing visible vendors.
        #expect(VendorOrder.moved(.anthropic, up: true, order: [.xai], visible: visible) == [.anthropic, .xai, .openai])
    }

    @Test("a step that moves nothing returns the stored order untouched")
    func no_op_returns_order() {
        let stored: [VendorId] = [.kimi, .anthropic, .openai]
        #expect(VendorOrder.moved(.anthropic, up: true, order: stored, visible: visible) == stored)
        #expect(VendorOrder.moved(.zai, up: true, order: stored, visible: visible) == stored)
        #expect(VendorOrder.moved(.xai, up: false, order: visible, visible: visible) == visible)
    }

    @Test("hidden vendors keep their slots; the step skips over them")
    func hidden_keep_slots() {
        // kimi is disabled (hidden) between anthropic and openai.
        #expect(VendorOrder.moved(.openai, up: true, order: [.anthropic, .kimi, .openai, .xai], visible: visible)
                == [.openai, .kimi, .anthropic, .xai])
        #expect(VendorOrder.moved(.anthropic, up: false, order: [.kimi, .anthropic, .openai, .xai], visible: visible)
                == [.kimi, .openai, .anthropic, .xai])
    }
}

@MainActor
@Suite("Service status panel ordering")
struct StatusPanelOrderTests {
    private func store(_ defaults: UserDefaults) -> ServiceStatusStore {
        ServiceStatusStore(vendorIds: [.anthropic, .openai, .xai], providers: [], defaults: defaults)
    }

    private func suite() -> (UserDefaults, String) {
        let name = "ai-taskbar.status.order.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("synced by default: rows follow the home order")
    func synced_follows_home() {
        let (d, name) = suite(); defer { d.removePersistentDomain(forName: name) }
        let s = store(d)
        #expect(s.syncVendorOrder)
        #expect(s.orderedRows(homeOrder: [.xai, .anthropic, .openai]).map(\.vendorId) == [.xai, .anthropic, .openai])
    }

    @Test("unsynced: own order, persisted, starting from the home order")
    func unsynced_own_order() {
        let (d, name) = suite(); defer { d.removePersistentDomain(forName: name) }
        let home: [VendorId] = [.xai, .anthropic, .openai]
        let s = store(d)
        s.syncVendorOrder = false
        s.adoptHomeOrder(home)
        s.moveVendor(.openai, up: true, homeOrder: home)
        #expect(s.orderedRows(homeOrder: home).map(\.vendorId) == [.xai, .openai, .anthropic])
        // The home order changing does not move the independent order.
        #expect(s.orderedRows(homeOrder: [.anthropic, .openai, .xai]).map(\.vendorId) == [.xai, .openai, .anthropic])
        // Persisted: a new store reads the same state.
        let reloaded = store(d)
        expectFalse(reloaded.syncVendorOrder)
        #expect(reloaded.orderedRows(homeOrder: home).map(\.vendorId) == [.xai, .openai, .anthropic])
    }

    @Test("turning sync back on follows the home order again")
    func resync() {
        let (d, name) = suite(); defer { d.removePersistentDomain(forName: name) }
        let s = store(d)
        s.syncVendorOrder = false
        s.moveVendor(.xai, up: true, homeOrder: [.anthropic, .openai, .xai])
        s.syncVendorOrder = true
        #expect(s.orderedRows(homeOrder: [.anthropic, .openai, .xai]).map(\.vendorId) == [.anthropic, .openai, .xai])
    }
}
