import Testing
import Foundation
import AppKit
@testable import AiTaskbarApp
@testable import AiTaskbarCore
@testable import AiTaskbarProviders

private struct MockUsageProvider: UsageProvider {
    let vendorId: VendorId
    var displayName: String { vendorId.displayName }
    var credentialFileURL: URL? { nil }
    func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        throw AppError.disabled("Mock")
    }
}

@Suite("PinnedStatusItem")
@MainActor
struct PinnedStatusItemTests {

    @Test("evaluateSpaceMath detects camera notch collision")
    func evaluate_space_notch_collision() {
        // Notch starts at 1010pt. Safe margin is 30pt (threshold = 1040pt).
        // If current minX is 1100pt and estimated item width is 72pt,
        // projectedMinX = 1028pt < 1040pt -> must be denied.
        let result = PinnedStatusItemManager.evaluateSpaceMath(
            minX: 1100.0,
            estimatedItemWidth: 72.0,
            notchRightEdge: 1010.0,
            safeNotchMargin: 30.0,
            screenVisibleOriginX: 0.0,
            screenWidth: 1800.0
        )

        expectFalse(result.allowed)
        #expect(result.reason == L10n.localizedString("pin_limit_notch_message"))
    }

    @Test("evaluateSpaceMath allows pinning when safe margin from notch is respected")
    func evaluate_space_notch_allowed() {
        // Notch starts at 1010pt. Safe margin is 30pt (threshold = 1040pt).
        // If current minX is 1200pt and estimated item width is 72pt,
        // projectedMinX = 1128pt >= 1040pt -> allowed.
        let result = PinnedStatusItemManager.evaluateSpaceMath(
            minX: 1200.0,
            estimatedItemWidth: 72.0,
            notchRightEdge: 1010.0,
            safeNotchMargin: 30.0,
            screenVisibleOriginX: 0.0,
            screenWidth: 1800.0
        )

        expectTrue(result.allowed)
        #expect(result.reason == nil)
    }

    @Test("evaluateSpaceMath checks left boundary on displays without notch")
    func evaluate_space_no_notch() {
        // Screen width 1920. Boundary = 0 + max(350, 1920 * 0.35) = 672pt.
        // minX = 700pt, item = 72pt -> projected = 628pt < 672pt -> denied.
        let denied = PinnedStatusItemManager.evaluateSpaceMath(
            minX: 700.0,
            estimatedItemWidth: 72.0,
            notchRightEdge: nil,
            safeNotchMargin: 30.0,
            screenVisibleOriginX: 0.0,
            screenWidth: 1920.0
        )
        expectFalse(denied.allowed)
        #expect(denied.reason == L10n.localizedString("pin_limit_screen_message"))

        // minX = 1200pt, item = 72pt -> projected = 1128pt >= 672pt -> allowed.
        let allowed = PinnedStatusItemManager.evaluateSpaceMath(
            minX: 1200.0,
            estimatedItemWidth: 72.0,
            notchRightEdge: nil,
            safeNotchMargin: 30.0,
            screenVisibleOriginX: 0.0,
            screenWidth: 1920.0
        )
        expectTrue(allowed.allowed)
        #expect(allowed.reason == nil)
    }

    @Test("canAddPinnedStatusItem enforces maximum cap of 5 items")
    func pin_limit_max_cap() {
        let manager = PinnedStatusItemManager.shared
        let res = manager.canAddPinnedStatusItem(currentPinnedCount: 5)
        expectFalse(res.allowed)
        #expect(res.reason == L10n.localizedString("pin_limit_count_message"))

        let res6 = manager.canAddPinnedStatusItem(currentPinnedCount: 6)
        expectFalse(res6.allowed)
        #expect(res6.reason == L10n.localizedString("pin_limit_count_message"))
    }

    @Test("togglePinned persists in insertion order, and re-pinning appends to the end")
    func toggle_pinned_preserves_insertion_order() {
        let name = "ai-taskbar.pinned.order.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }

        let v1 = VendorViewModel(provider: MockUsageProvider(vendorId: .anthropic))
        let v2 = VendorViewModel(provider: MockUsageProvider(vendorId: .openai))
        let v3 = VendorViewModel(provider: MockUsageProvider(vendorId: .openrouter))
        let v4 = VendorViewModel(provider: MockUsageProvider(vendorId: .gemini))

        let store = UsageStore(
            vendors: [v1, v2, v3, v4],
            primary: nil,
            preferredOrder: [.anthropic, .openai, .openrouter, .gemini]
        )

        // Pin in custom activation order: openrouter, anthropic, openai
        store.togglePinned(.openrouter, defaults: suite)
        store.togglePinned(.anthropic, defaults: suite)
        store.togglePinned(.openai, defaults: suite)

        // The persisted array preserves the user's activation/insertion order
        let persisted = suite.stringArray(forKey: UsageStore.pinnedDefaultsKey) ?? []
        #expect(persisted == ["openrouter", "anthropic", "openai"])

        // Unpin anthropic
        store.togglePinned(.anthropic, defaults: suite)
        let afterUnpin = suite.stringArray(forKey: UsageStore.pinnedDefaultsKey) ?? []
        #expect(afterUnpin == ["openrouter", "openai"])

        // Re-pin anthropic: it must be appended to the END, not inserted in the middle!
        store.togglePinned(.anthropic, defaults: suite)
        let afterRepin = suite.stringArray(forKey: UsageStore.pinnedDefaultsKey) ?? []
        #expect(afterRepin == ["openrouter", "openai", "anthropic"])
    }

    @Test("togglePinned blocks and triggers pinLimitAlert when cap is reached")
    func toggle_pinned_blocks_when_cap_reached() {
        let name = "ai-taskbar.pinned.cap.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }

        let v1 = VendorViewModel(provider: MockUsageProvider(vendorId: .anthropic))
        let v2 = VendorViewModel(provider: MockUsageProvider(vendorId: .openai))
        let v3 = VendorViewModel(provider: MockUsageProvider(vendorId: .openrouter))
        let v4 = VendorViewModel(provider: MockUsageProvider(vendorId: .gemini))
        let v5 = VendorViewModel(provider: MockUsageProvider(vendorId: .kimi))
        let v6 = VendorViewModel(provider: MockUsageProvider(vendorId: .zai))

        let store = UsageStore(
            vendors: [v1, v2, v3, v4, v5, v6],
            primary: nil,
            preferredOrder: [.anthropic, .openai, .openrouter, .gemini, .kimi, .zai]
        )

        // Pin 5 models
        store.togglePinned(.anthropic, defaults: suite)
        store.togglePinned(.openai, defaults: suite)
        store.togglePinned(.openrouter, defaults: suite)
        store.togglePinned(.gemini, defaults: suite)
        store.togglePinned(.kimi, defaults: suite)

        expectTrue(store.isPinned(.anthropic))
        expectTrue(store.isPinned(.openai))
        expectTrue(store.isPinned(.openrouter))
        expectTrue(store.isPinned(.gemini))
        expectTrue(store.isPinned(.kimi))
        #expect(store.pinLimitAlert == nil)

        // Attempting to pin the 6th model must be blocked by the 5-item cap!
        store.togglePinned(.zai, defaults: suite)
        expectFalse(store.isPinned(.zai))
        #expect(store.pinLimitAlert != nil)
        #expect(store.pinLimitAlert?.title == L10n.localizedString("pin_limit_reached_title"))
        #expect(store.pinLimitAlert?.message == L10n.localizedString("pin_limit_count_message"))
    }

    @Test("syncStatusItems retains untouched status items in place without destroying all items")
    func sync_status_items_slot_diffing_avoids_flicker() {
        let name = "ai-taskbar.pinned.flicker.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }

        let v1 = VendorViewModel(provider: MockUsageProvider(vendorId: .anthropic))
        let v2 = VendorViewModel(provider: MockUsageProvider(vendorId: .openai))
        let v3 = VendorViewModel(provider: MockUsageProvider(vendorId: .openrouter))

        let store = UsageStore(
            vendors: [v1, v2, v3],
            primary: nil,
            preferredOrder: [.anthropic, .openai, .openrouter]
        )

        let manager = PinnedStatusItemManager()
        defer { manager.removeAll() }

        manager.configure(store: store)
        #expect(manager.physicalItems.count == 0)

        // 1. Pin Anthropic and OpenAI (2 items)
        store.togglePinned(.anthropic, defaults: suite)
        store.togglePinned(.openai, defaults: suite)
        manager.syncStatusItems()

        #expect(manager.physicalItems.count == 2)
        let anthropicItem = manager.statusItem(for: .anthropic)
        #expect(anthropicItem != nil)

        // 2. Unpin OpenAI (down to 1 item)
        store.togglePinned(.openai, defaults: suite)
        manager.syncStatusItems()

        #expect(manager.physicalItems.count == 1)
        // Anthropic item is retained in place without being recreated!
        #expect(manager.statusItem(for: .anthropic) === anthropicItem)
        #expect(manager.statusItem(for: .openai) == nil)

        // 3. Re-pin OpenAI (back to 2 items)
        store.togglePinned(.openai, defaults: suite)
        manager.syncStatusItems()

        #expect(manager.physicalItems.count == 2)
        // Anthropic item is STILL retained in place!
        #expect(manager.statusItem(for: .anthropic) === anthropicItem)
        #expect(manager.statusItem(for: .openai) != nil)
    }
}
