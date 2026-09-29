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

    @Test("each pinned item gets a stable per-vendor autosave name")
    func pinned_items_carry_stable_autosave_names() {
        let name = "ai-taskbar.pinned.autosave.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }

        let v1 = VendorViewModel(provider: MockUsageProvider(vendorId: .anthropic))
        let v2 = VendorViewModel(provider: MockUsageProvider(vendorId: .openai))
        let store = UsageStore(vendors: [v1, v2], primary: nil,
                               preferredOrder: [.anthropic, .openai])
        let manager = PinnedStatusItemManager()
        defer { manager.removeAll() }
        manager.configure(store: store)

        store.togglePinned(.anthropic, defaults: suite)
        store.togglePinned(.openai, defaults: suite)
        manager.syncStatusItems()
        // Unpin then re-pin: the path whose anonymous re-created item never
        // reached the screen on macOS 26.
        store.togglePinned(.anthropic, defaults: suite)
        manager.syncStatusItems()
        store.togglePinned(.anthropic, defaults: suite)
        manager.syncStatusItems()

        #expect(manager.statusItem(for: .anthropic)?.autosaveName == "ai-taskbar.pinned.anthropic")
        #expect(manager.statusItem(for: .openai)?.autosaveName == "ai-taskbar.pinned.openai")
        #expect(manager.currentOrderedPinned == [.openai, .anthropic])
    }

    @Test("autosave names are distinct for every vendor")
    func autosave_names_are_unique() {
        let names = VendorId.allCases.map(PinnedStatusItemManager.autosaveName(for:))
        #expect(Set(names).count == VendorId.allCases.count)
    }

    @Test("status-item filter keeps only item-sized windows in the menu-bar strip")
    func status_items_min_x_filters_non_items() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let rects = [
            CGRect(x: 0, y: 0, width: 1800, height: 39),      // the bar itself
            CGRect(x: 1216, y: 0, width: 66, height: 39),     // an item
            CGRect(x: 1152, y: 0, width: 56, height: 39),     // leftmost item
            CGRect(x: 400, y: 300, width: 80, height: 30),    // a window mid-screen
            CGRect(x: 2000, y: 0, width: 40, height: 39)      // another display
        ]
        #expect(PinnedStatusItemManager.statusItemsMinX(windowRects: rects, screenFrame: screen) == 1152)
        expectTrue(PinnedStatusItemManager.statusItemsMinX(windowRects: [], screenFrame: screen) == nil)
    }

    @Test("an item the system already hid still counts as occupied space")
    func leftmost_x_includes_hidden_own_items() {
        // WindowServer draws nothing left of 1046, but this app has an item
        // AppKit placed at 878 — under the notch. The bar is already full.
        let own = [CGRect(x: 1163, y: 0, width: 53, height: 39),
                   CGRect(x: 878, y: 0, width: 29, height: 39)]
        #expect(PinnedStatusItemManager.menuBarLeftmostX(visibleMinX: 1046, ownFrames: own) == 878)
    }

    @Test("unplaced own items (x = 0) are ignored, not read as a full bar")
    func leftmost_x_ignores_unplaced_frames() {
        let own = [CGRect(x: 0, y: 0, width: 29, height: 39),
                   CGRect(x: 1163, y: 0, width: 53, height: 39)]
        #expect(PinnedStatusItemManager.menuBarLeftmostX(visibleMinX: 1216, ownFrames: own) == 1163)
        expectTrue(PinnedStatusItemManager.menuBarLeftmostX(visibleMinX: nil, ownFrames: []) == nil)
        #expect(PinnedStatusItemManager.menuBarLeftmostX(visibleMinX: 1216, ownFrames: []) == 1216)
    }

    @Test("worst-case badge width is measured, and wider than the old 50 pt guess")
    func worst_case_badge_width_is_measured() {
        let width = PinnedStatusItemManager.worstCaseBadgeWidth(thresholds: .init())
        // A loaded badge measured 56 pt on a real bar; the widest layout adds
        // the flame, so anything at or under the old estimate is wrong.
        #expect(width > 56)
        #expect(width < 150)
    }

    @Test("a slot that fits a narrow badge but not a full one is denied")
    func narrow_guess_would_have_allowed_overflow() {
        // Real geometry: notch right edge 1010, leftmost item at 1080.
        // The old 50 pt guess projects 1030 (>= 1018) and allowed the pin;
        // a real badge does not fit.
        let width = PinnedStatusItemManager.worstCaseBadgeWidth(thresholds: .init())
        let result = PinnedStatusItemManager.evaluateSpaceMath(
            minX: 1080, estimatedItemWidth: width, notchRightEdge: 1010, safeNotchMargin: 8
        )
        expectFalse(result.allowed)
    }

    @Test("item length formula keeps the 42 pt floor")
    func pinned_item_length_floor() {
        #expect(PinnedStatusItemManager.pinnedItemLength(forContentWidth: 10) == 42)
        #expect(PinnedStatusItemManager.pinnedItemLength(forContentWidth: 60) == 66)
    }
}
