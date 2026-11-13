import Testing
import Foundation
import AppKit
@testable import AiTaskbarApp
@testable import AiTaskbarCore

/// A pinned item's click: what it does to the popover, and how the main
/// popover is triggered on macOS ≤ 26 vs macOS 27 (scene status items).
@Suite("PinnedClick")
@MainActor
struct PinnedClickTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: decideClick

    @Test("closed popover: a click focuses the LLM and opens the popover")
    func closed_opens() {
        let d = PinnedStatusItemManager.decideClick(
            clicked: .anthropic, isPresented: false, lastFocused: nil, recentClose: nil, now: t0
        )
        #expect(d == .focus(openPopover: true))
    }

    @Test("open on the same LLM: the click closes it")
    func open_same_closes() {
        let d = PinnedStatusItemManager.decideClick(
            clicked: .anthropic, isPresented: true, lastFocused: .anthropic, recentClose: nil, now: t0
        )
        #expect(d == .close)
    }

    @Test("open on another LLM: the click refocuses without reopening")
    func open_other_refocuses() {
        let d = PinnedStatusItemManager.decideClick(
            clicked: .openai, isPresented: true, lastFocused: .anthropic, recentClose: nil, now: t0
        )
        #expect(d == .focus(openPopover: false))
    }

    @Test("macOS 27: the click on the same LLM already closed the popover, so it stays closed")
    func dismissed_by_same_click_stays_closed() {
        let close = PinnedStatusItemManager.RecentClose(vendor: .anthropic, at: t0)
        let d = PinnedStatusItemManager.decideClick(
            clicked: .anthropic, isPresented: false, lastFocused: nil, recentClose: close,
            now: t0.addingTimeInterval(0.05), clickDismissesPopoverFirst: true
        )
        #expect(d == .ignore)
    }

    @Test("macOS 27: a click on ANOTHER LLM right after the dismissal reopens on it")
    func dismissed_then_other_reopens() {
        let close = PinnedStatusItemManager.RecentClose(vendor: .anthropic, at: t0)
        let d = PinnedStatusItemManager.decideClick(
            clicked: .openai, isPresented: false, lastFocused: nil, recentClose: close,
            now: t0.addingTimeInterval(0.05), clickDismissesPopoverFirst: true
        )
        #expect(d == .focus(openPopover: true))
    }

    @Test("a close older than the dismissal window does not swallow the next click")
    func old_close_does_not_swallow() {
        let close = PinnedStatusItemManager.RecentClose(vendor: .anthropic, at: t0)
        let d = PinnedStatusItemManager.decideClick(
            clicked: .anthropic, isPresented: false, lastFocused: nil, recentClose: close,
            now: t0.addingTimeInterval(PinnedStatusItemManager.dismissedByClickWindow),
            clickDismissesPopoverFirst: true
        )
        #expect(d == .focus(openPopover: true))
    }

    @Test("a close stamped in the future (clock skew) does not swallow the click")
    func future_close_does_not_swallow() {
        let close = PinnedStatusItemManager.RecentClose(vendor: .anthropic, at: t0.addingTimeInterval(10))
        let d = PinnedStatusItemManager.decideClick(
            clicked: .anthropic, isPresented: false, lastFocused: nil, recentClose: close, now: t0,
            clickDismissesPopoverFirst: true
        )
        #expect(d == .focus(openPopover: true))
    }

    @Test("macOS ≤ 26: a recent close never swallows a click (previous behavior)")
    func pre_27_never_swallows() {
        let close = PinnedStatusItemManager.RecentClose(vendor: .anthropic, at: t0)
        let d = PinnedStatusItemManager.decideClick(
            clicked: .anthropic, isPresented: false, lastFocused: nil, recentClose: close,
            now: t0.addingTimeInterval(0.05), clickDismissesPopoverFirst: false
        )
        #expect(d == .focus(openPopover: true))
    }

    // MARK: handleClick state

    @Test("macOS 27: a dismissal records the focused LLM; the swallowed click consumes it",
          .enabled(if: MainPopoverTrigger.isSceneStatusItemOS))
    func handle_click_records_and_consumes_recent_close() {
        let manager = PinnedStatusItemManager()
        var clock = t0
        manager.now = { clock }

        manager.handleClick(on: .anthropic)
        #expect(manager.lastFocusedPinnedVendor == .anthropic)

        // The popover's onDisappear (the click on the item dismissed it).
        manager.clearLastFocusedPinnedVendor()
        #expect(manager.lastFocusedPinnedVendor == nil)
        #expect(manager.recentClose == .init(vendor: .anthropic, at: t0))

        clock = t0.addingTimeInterval(0.1)
        manager.handleClick(on: .anthropic)
        #expect(manager.lastFocusedPinnedVendor == nil)
        #expect(manager.recentClose == nil)

        // The next click, whenever it comes, opens again.
        manager.handleClick(on: .anthropic)
        #expect(manager.lastFocusedPinnedVendor == .anthropic)
    }

    @Test("closing with no pinned focus records no recent close")
    func close_without_focus_records_nothing() {
        let manager = PinnedStatusItemManager()
        manager.clearLastFocusedPinnedVendor()
        #expect(manager.recentClose == nil)
    }

    // MARK: reconcileClosedPopover (macOS 27)

    private func managerWithStore(windowShowing: Bool?) -> (PinnedStatusItemManager, UsageStore, Counter) {
        let store = UsageStore(vendors: [], primary: nil, preferredOrder: [])
        let manager = PinnedStatusItemManager()
        manager.configure(store: store)
        manager.now = { [t0] in t0 }
        manager.popoverWindowShowing = { windowShowing }
        let resyncs = Counter()
        manager.resyncPopoverWindow = { resyncs.value += 1 }
        return (manager, store, resyncs)
    }

    @Test("macOS 27: store says open, window is gone → the close is applied before deciding")
    func reconcile_applies_missed_close() {
        let (manager, store, resyncs) = managerWithStore(windowShowing: false)
        manager.handleClick(on: .anthropic)          // focus + open
        store.isPopoverPresented = true              // the popover opened
        let reconciled = manager.reconcileClosedPopover(isSceneStatusItemOS: true)
        #expect(reconciled)
        #expect(resyncs.value == 1)
        expectFalse(store.isPopoverPresented)
        #expect(manager.recentClose == .init(vendor: .anthropic, at: t0))
        #expect(manager.lastFocusedPinnedVendor == nil)
    }

    @Test("macOS 27: the toggle click on the same LLM leaves the popover closed",
          .enabled(if: MainPopoverTrigger.isSceneStatusItemOS))
    func reconcile_then_same_click_is_ignored() {
        let (manager, store, _) = managerWithStore(windowShowing: false)
        manager.handleClick(on: .anthropic)
        store.isPopoverPresented = true
        manager.handleClick(on: .anthropic)          // the click already hid it
        #expect(manager.lastFocusedPinnedVendor == nil)
        expectFalse(store.isPopoverPresented)
    }

    @Test("window still showing → nothing to reconcile")
    func reconcile_skips_when_window_showing() {
        let (manager, store, resyncs) = managerWithStore(windowShowing: true)
        store.isPopoverPresented = true
        expectFalse(manager.reconcileClosedPopover(isSceneStatusItemOS: true))
        #expect(resyncs.value == 0)
        expectTrue(store.isPopoverPresented)
    }

    @Test("window never seen → nothing to reconcile")
    func reconcile_skips_unknown_window() {
        let (manager, store, _) = managerWithStore(windowShowing: nil)
        store.isPopoverPresented = true
        expectFalse(manager.reconcileClosedPopover(isSceneStatusItemOS: true))
        expectTrue(store.isPopoverPresented)
    }

    @Test("macOS ≤ 26 never reconciles: onDisappear keeps the store right there")
    func reconcile_never_before_27() {
        let (manager, store, resyncs) = managerWithStore(windowShowing: false)
        store.isPopoverPresented = true
        expectFalse(manager.reconcileClosedPopover(isSceneStatusItemOS: false))
        #expect(resyncs.value == 0)
        expectTrue(store.isPopoverPresented)
    }

    @Test("an observer that already applied the close leaves nothing for the fallback")
    func reconcile_observer_handles_close() {
        let (manager, store, _) = managerWithStore(windowShowing: false)
        manager.handleClick(on: .anthropic)
        store.isPopoverPresented = true
        manager.resyncPopoverWindow = {
            // What PopoverContentView.popoverDidClose does.
            store.isPopoverPresented = false
            manager.clearLastFocusedPinnedVendor()
        }
        #expect(manager.reconcileClosedPopover(isSceneStatusItemOS: true))
        #expect(manager.recentClose == .init(vendor: .anthropic, at: t0))
    }

    // MARK: MainPopoverTrigger.route

    @Test("a button with target/action keeps the old route on every macOS")
    func route_prefers_button_action() {
        for os27 in [false, true] {
            for scene in [false, true] {
                let r = MainPopoverTrigger.route(hasTargetAction: true, supportsSceneSession: scene, isSceneStatusItemOS: os27)
                #expect(r == .buttonAction)
            }
        }
    }

    @Test("macOS 27: no target/action, scene session available → scene session")
    func route_scene_session() {
        let r = MainPopoverTrigger.route(hasTargetAction: false, supportsSceneSession: true, isSceneStatusItemOS: true)
        #expect(r == .sceneSession)
    }

    @Test("macOS ≤ 26 never uses the private scene calls, even if they exist")
    func route_pre_27_never_scene() {
        let r = MainPopoverTrigger.route(hasTargetAction: false, supportsSceneSession: true, isSceneStatusItemOS: false)
        #expect(r == .performClick)
    }

    @Test("neither available → performClick as the last resort")
    func route_perform_click() {
        let r = MainPopoverTrigger.route(hasTargetAction: false, supportsSceneSession: false, isSceneStatusItemOS: true)
        #expect(r == .performClick)
    }

    @Test("a plain button without a status item is not a scene item")
    func plain_button_is_not_scene_item() {
        let button = NSStatusBarButton(frame: .zero)
        #expect(MainPopoverTrigger.sceneStatusItem(of: button) == nil)
    }

    @Test("macOS 13-26 keep the content dissolve on open")
    func dissolveKeptBefore27() {
        #expect(MainPopoverTrigger.dissolvesContentOnOpen(isSceneStatusItemOS: false))
    }

    @Test("macOS 27 never dissolves content the window already shows")
    func noDissolveOn27() {
        #expect(!MainPopoverTrigger.dissolvesContentOnOpen(isSceneStatusItemOS: true))
    }
}

@MainActor
private final class Counter {
    var value = 0
}
