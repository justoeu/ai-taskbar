import Testing
import Foundation
import AppKit
@testable import AiTaskbarApp
@testable import AiTaskbarCore

@Suite("VendorOrder")
struct VendorOrderTests {
    @Test("all vendor icons load as valid NSImage")
    @MainActor
    func vendor_icons_load() {
        for v in VendorId.allCases {
            let img = VendorIconAssets.image(for: v)
            #expect(img != nil, "Image for \(v) must not be nil")
            if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                var visiblePixels = 0
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.1 {
                            visiblePixels += 1
                        }
                    }
                }
                #expect(visiblePixels > 50, "Vendor \(v) must have visible pixels, got \(visiblePixels)")
            }
        }
    }

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

    @Test("UsageStore pin and toggle pinned vendors")
    @MainActor
    func usage_store_pin_vendors() {
        let name = "ai-taskbar.pinned.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }

        let store = UsageStore(vendors: [], primary: nil)
        #expect(!store.isPinned(.anthropic))

        store.togglePinned(.anthropic, defaults: suite)
        #expect(store.isPinned(.anthropic))
        #expect(suite.stringArray(forKey: UsageStore.pinnedDefaultsKey) == ["anthropic"])

        store.togglePinned(.anthropic, defaults: suite)
        #expect(!store.isPinned(.anthropic))
    }
}
