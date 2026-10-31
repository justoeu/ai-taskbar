import Testing
import AppKit
@testable import AiTaskbarApp

/// ← / → on the account switcher: which keys count, which switcher they
/// drive, and when they are left alone.
@MainActor
@Suite("Account switcher keyboard", .serialized)
struct AccountSwitcherKeyboardTests {
    private func handle(_ log: Box) -> AccountSwitcherHandle {
        let h = AccountSwitcherHandle()
        h.step = { log.steps.append($0) }
        return h
    }

    final class Box { var steps: [Int] = [] }

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

    @Test("arrows are left to a text field being edited and to modals")
    func popover_guard() {
        expectTrue(PopoverKeyMonitor.arrowsDriveSwitcher(modalShown: false, editingText: false))
        expectFalse(PopoverKeyMonitor.arrowsDriveSwitcher(modalShown: false, editingText: true))
        expectFalse(PopoverKeyMonitor.arrowsDriveSwitcher(modalShown: true, editingText: false))
    }

    @Test("an arrow aimed at another window is not consumed")
    func other_window() {
        let monitor = PopoverKeyMonitor()
        expectFalse(monitor.handle(keyCode: 124, modifiers: [], windowNumber: 42))
    }

    @Test("arrow destinations wrap around both ends")
    func destinations() {
        #expect(AccountSwitcherView.destination(from: 0, by: -1, count: 2) == 1)
        #expect(AccountSwitcherView.destination(from: 1, by: 1, count: 2) == 0)
        #expect(AccountSwitcherView.destination(from: 0, by: 1, count: 3) == 1)
        #expect(AccountSwitcherView.destination(from: 2, by: 1, count: 3) == 0)
    }
}
