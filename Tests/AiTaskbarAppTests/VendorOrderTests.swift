import Testing
import Foundation
@testable import AiTaskbarApp
@testable import AiTaskbarCore

@Suite("VendorOrder")
struct VendorOrderTests {
    @Test("empty preferred → configured first, then alpha")
    func default_configured_first_alpha() {
        let entries: [(VendorId, Bool)] = [
            (.zai, true),
            (.anthropic, false),
            (.deepseek, false),
            (.openai, true),
        ]
        let ids = VendorOrder.ordered(entries: entries.map { ($0.0, $0.1) }, preferred: [])
        #expect(ids == [.anthropic, .deepseek, .openai, .zai])
    }

    @Test("preferred order wins for known IDs")
    func preferred_order_wins() {
        let entries: [(VendorId, Bool)] = [
            (.anthropic, false),
            (.openai, false),
            (.xai, false),
        ]
        let preferred: [VendorId] = [.xai, .anthropic, .openai]
        let ids = VendorOrder.ordered(entries: entries.map { ($0.0, $0.1) },
                                      preferred: preferred)
        #expect(ids == [.xai, .anthropic, .openai])
    }

    @Test("preferred ignores IDs not currently available")
    func preferred_drops_missing() {
        let entries: [(VendorId, Bool)] = [
            (.kimi, false),
            (.gemini, false),
        ]
        let preferred: [VendorId] = [.xai, .kimi, .anthropic, .gemini]
        let ids = VendorOrder.ordered(entries: entries.map { ($0.0, $0.1) },
                                      preferred: preferred)
        #expect(ids == [.kimi, .gemini])
    }

    @Test("new vendors not in preferred are appended configured-first")
    func missing_from_preferred_appended() {
        let entries: [(VendorId, Bool)] = [
            (.anthropic, false),
            (.xai, false),
            (.zai, true),
        ]
        // User only ordered anthropic before; xai + zai are new.
        let preferred: [VendorId] = [.anthropic]
        let ids = VendorOrder.ordered(entries: entries.map { ($0.0, $0.1) },
                                      preferred: preferred)
        #expect(ids.first == .anthropic)
        #expect(ids.contains(.xai))
        #expect(ids.last == .zai)
        #expect(ids == [.anthropic, .xai, .zai])
    }

    @Test("move reorders array")
    func moving_reorders() {
        let order: [VendorId] = [.anthropic, .openai, .xai]
        // Move xai (index 2) to front (toOffset 0).
        let moved = VendorOrder.moving(order, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(moved == [.xai, .anthropic, .openai])
    }

    @Test("moving id before target")
    func moving_id_before_target() {
        let order: [VendorId] = [.anthropic, .openai, .xai]
        #expect(VendorOrder.moving(order, id: .xai, before: .anthropic)
                == [.xai, .anthropic, .openai])
        #expect(VendorOrder.moving(order, id: .anthropic, before: .xai)
                == [.openai, .anthropic, .xai])
        #expect(VendorOrder.moving(order, id: .openai, before: .openai) == order)
        #expect(VendorOrder.moving(order, id: .xai, before: nil)
                == [.anthropic, .openai, .xai])
    }

    @Test("swap adjacent steps match up/down")
    func adjacent_swap() {
        var order: [VendorId] = [.anthropic, .openai, .xai]
        order.swapAt(1, 0) // openai up
        #expect(order == [.openai, .anthropic, .xai])
        order.swapAt(1, 2) // anthropic down
        #expect(order == [.openai, .xai, .anthropic])
    }

    @Test("save and load round-trip via UserDefaults suite")
    func save_load_round_trip() {
        let name = "ai-taskbar.vendor-order.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        let order: [VendorId] = [.xai, .deepseek, .kimi]
        VendorOrder.save(order, to: suite)
        let loaded = VendorOrder.load(from: suite)
        #expect(loaded == order)
        VendorOrder.clear(from: suite)
        #expect(VendorOrder.load(from: suite).isEmpty)
    }

    @Test("load skips unknown raw values")
    func load_skips_unknown() {
        let name = "ai-taskbar.vendor-order.unknown.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        suite.set(["xai", "not-a-vendor", "kimi"], forKey: VendorOrder.defaultsKey)
        let loaded = VendorOrder.load(from: suite)
        #expect(loaded == [.xai, .kimi])
    }
}
