import Testing
import AppKit
import SwiftUI
@testable import AiTaskbarApp

/// ← / → on the account switcher: which keys count, which switcher they
/// drive, and when they are left alone.
@MainActor
@Suite("Account switcher keyboard", .serialized)
struct AccountSwitcherKeyboardTests {
    /// A switcher over accounts a, b, c showing `a`; `log.steps` records the
    /// offset each selection represents relative to `a` (+1 = b, -1 = c), so
    /// the routing tests read as steps.
    private func handle(_ log: Box) -> AccountSwitcherHandle {
        let h = AccountSwitcherHandle()
        h.update(ids: ["a", "b", "c"], selectedID: "a") { id in
            log.selected.append(id)
            log.steps.append(id == "b" ? 1 : (id == "c" ? -1 : 0))
        }
        return h
    }

    final class Box {
        var steps: [Int] = []
        var selected: [String] = []
    }

    /// Renders the real view in a window and drives it through the shared
    /// registry, the same path a key press takes. This is what catches the
    /// wiring regression: refreshing the handle from `onChange(of:
    /// selectedID)` (or only `onAppear`) left it holding the pre-click
    /// selection on macOS 13, and → re-selected the account already shown.
    @Test("hosted switcher: after the selection changes, → steps from the new one")
    func hosted_view_steps_from_current_selection() {
        let log = Box()
        let ids = ["main", "work"]
        func view(_ selected: String) -> AccountSwitcherView {
            AccountSwitcherView(chips: ids.map { AccountChip(id: $0, name: $0) },
                                selectedID: selected,
                                onSelect: { log.selected.append($0) })
        }
        let host = NSHostingView(rootView: view("main"))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        settle()
        expectTrue(AccountSwitcherKeyboard.shared.step(by: 1))
        #expect(log.selected == ["work"])
        // The selection changes (a click on ›, or the key above landing).
        host.rootView = view("work")
        settle()
        expectTrue(AccountSwitcherKeyboard.shared.step(by: 1))
        #expect(log.selected == ["work", "main"])
        window.contentView = nil
        settle()
        expectFalse(AccountSwitcherKeyboard.shared.step(by: 1))   // unregistered on disappear
    }

    @Test("a handle steps from the selection it was last given")
    func step_uses_live_selection() {
        let log = Box()
        let h = AccountSwitcherHandle()
        let select: (String) -> Void = { log.selected.append($0) }
        h.update(ids: ["main", "work"], selectedID: "main", onSelect: select)
        h.update(ids: ["main", "work"], selectedID: "work", onSelect: select)   // clicked ›
        h.step(1)
        #expect(log.selected == ["main"])
        h.update(ids: ["main", "work"], selectedID: "main", onSelect: select)
        h.step(-1)
        #expect(log.selected == ["main", "work"])
    }

    @Test("a handle with no accounts does nothing")
    func empty_handle() {
        let log = Box()
        let h = AccountSwitcherHandle()
        h.update(ids: [], selectedID: "", onSelect: { log.selected.append($0) })
        h.step(1)
        #expect(log.selected.isEmpty)
    }

    @Test("plain ← and → map to -1 and +1; arrows carry numericPad/function")
    func offsets() {
        #expect(AccountSwitcherKeyboard.offset(keyCode: 123, modifiers: [.numericPad, .function]) == -1)
        #expect(AccountSwitcherKeyboard.offset(keyCode: 124, modifiers: [.numericPad, .function]) == 1)
        #expect(AccountSwitcherKeyboard.offset(keyCode: 124, modifiers: []) == 1)
    }

    @Test("modified arrows and other keys are not account steps")
    func non_offsets() {
        #expect(AccountSwitcherKeyboard.offset(keyCode: 124, modifiers: [.command]) == nil)
        #expect(AccountSwitcherKeyboard.offset(keyCode: 123, modifiers: [.option]) == nil)
        #expect(AccountSwitcherKeyboard.offset(keyCode: 123, modifiers: [.shift]) == nil)
        #expect(AccountSwitcherKeyboard.offset(keyCode: 125, modifiers: []) == nil)   // ↓
        #expect(AccountSwitcherKeyboard.offset(keyCode: 53, modifiers: []) == nil)    // Esc
    }

    @Test("the only enabled switcher takes the arrows")
    func single_switcher() {
        let keyboard = AccountSwitcherKeyboard()
        let log = Box()
        let h = handle(log)
        keyboard.register(h, enabled: true)
        expectTrue(keyboard.step(by: 1))
        expectTrue(keyboard.step(by: -1))
        #expect(log.steps == [1, -1])
    }

    @Test("a disabled switcher (home under the Analytics page) is skipped")
    func disabled_is_skipped() {
        let keyboard = AccountSwitcherKeyboard()
        let home = Box(), analytics = Box()
        let h = handle(home), a = handle(analytics)
        keyboard.register(h, enabled: false)
        keyboard.register(a, enabled: true)
        expectTrue(keyboard.step(by: 1))
        #expect(home.steps.isEmpty)
        #expect(analytics.steps == [1])
    }

    @Test("with several enabled and no hint the arrows are left alone")
    func ambiguous_is_left_alone() {
        let keyboard = AccountSwitcherKeyboard()
        let a = handle(Box()), b = handle(Box())
        keyboard.register(a, enabled: true)
        keyboard.register(b, enabled: true)
        expectFalse(keyboard.step(by: 1))
    }

    @Test("hover wins, then the switcher last used")
    func hover_then_last_used() {
        let keyboard = AccountSwitcherKeyboard()
        let first = Box(), second = Box()
        let a = handle(first), b = handle(second)
        keyboard.register(a, enabled: true)
        keyboard.register(b, enabled: true)
        keyboard.markUsed(a)
        keyboard.setHovered(b, true)
        _ = keyboard.step(by: 1)
        #expect(second.steps == [1])
        keyboard.setHovered(b, false)
        _ = keyboard.step(by: -1)
        // Stepping marks the switcher used, so b is now the last used.
        #expect(second.steps == [1, -1])
        #expect(first.steps.isEmpty)
    }

    @Test("an unregistered switcher is never driven")
    func unregistered() {
        let keyboard = AccountSwitcherKeyboard()
        let log = Box()
        let h = handle(log)
        keyboard.register(h, enabled: true)
        keyboard.setHovered(h, true)
        keyboard.unregister(h)
        expectFalse(keyboard.step(by: 1))
        #expect(log.steps.isEmpty)
    }

    @Test("arrows are left to a focused control and to modals")
    func popover_guard() {
        expectTrue(PopoverKeyMonitor.arrowsDriveSwitcher(modalShown: false, focusedControl: false))
        expectFalse(PopoverKeyMonitor.arrowsDriveSwitcher(modalShown: false, focusedControl: true))
        expectFalse(PopoverKeyMonitor.arrowsDriveSwitcher(modalShown: true, focusedControl: false))
    }

    @Test("text fields and controls keep their arrows; the window and plain views do not")
    func controls_using_arrows() {
        expectTrue(PopoverKeyMonitor.usesArrowKeys(NSTextView()))
        expectTrue(PopoverKeyMonitor.usesArrowKeys(NSSegmentedControl()))
        expectTrue(PopoverKeyMonitor.usesArrowKeys(NSSlider()))
        expectFalse(PopoverKeyMonitor.usesArrowKeys(NSView()))
        expectFalse(PopoverKeyMonitor.usesArrowKeys(nil))
    }

    @Test("the popover window's arrow drives the switcher; another window's does not")
    func window_scoping() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 50, height: 50),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let monitor = PopoverKeyMonitor()
        monitor.window = window
        let log = Box()
        let h = handle(log)
        AccountSwitcherKeyboard.shared.register(h, enabled: true)
        defer { AccountSwitcherKeyboard.shared.unregister(h) }
        expectFalse(monitor.handle(keyCode: 124, modifiers: [], windowNumber: window.windowNumber + 1))
        #expect(log.steps.isEmpty)
        expectTrue(monitor.handle(keyCode: 124, modifiers: [], windowNumber: window.windowNumber))
        #expect(log.steps == [1])
    }

    @Test("arrow destinations wrap around both ends")
    func destinations() {
        #expect(AccountSwitcherView.destination(from: 0, by: -1, count: 2) == 1)
        #expect(AccountSwitcherView.destination(from: 1, by: 1, count: 2) == 0)
        #expect(AccountSwitcherView.destination(from: 0, by: 1, count: 3) == 1)
        #expect(AccountSwitcherView.destination(from: 2, by: 1, count: 3) == 0)
    }
}
