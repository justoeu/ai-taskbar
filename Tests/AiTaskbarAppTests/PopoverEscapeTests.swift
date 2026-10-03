import Testing
import AppKit
@testable import AiTaskbarApp

@Suite("Popover Esc")
struct PopoverEscapeTests {
    @Test("Esc closes the popover from any screen")
    func closes() {
        #expect(PopoverEscape.action(modalShown: false) == .closePopover)
    }

    @Test("an open modal gets Esc first")
    func modal_first() {
        #expect(PopoverEscape.action(modalShown: true) == .passToModal)
    }

    @Test("only a plain Esc counts")
    func plain_escape() {
        #expect(PopoverKeyMonitor.isPlainEscape(keyCode: 53, modifiers: []))
        #expect(PopoverKeyMonitor.isPlainEscape(keyCode: 53, modifiers: [.capsLock, .numericPad]))
        #expect(!PopoverKeyMonitor.isPlainEscape(keyCode: 53, modifiers: [.command]))
        #expect(!PopoverKeyMonitor.isPlainEscape(keyCode: 53, modifiers: [.option]))
        #expect(!PopoverKeyMonitor.isPlainEscape(keyCode: 53, modifiers: [.shift]))
        #expect(!PopoverKeyMonitor.isPlainEscape(keyCode: 53, modifiers: [.control]))
        #expect(PopoverKeyMonitor.escapeKeyCode == 53)
        #expect(!PopoverKeyMonitor.isPlainEscape(keyCode: 36, modifiers: []))
    }

    @MainActor
    @Test("About's confirmation counts as a modal")
    func modal_state() {
        let m = PopoverKeyMonitor.shared
        let savedStore = m.store
        defer { m.aboutConfirmationShown = false; m.store = savedStore }
        m.store = nil
        #expect(!m.modalShown)
        m.aboutConfirmationShown = true
        #expect(m.modalShown)
    }

    @MainActor
    @Test("Esc from any other window, or with no popover window, is not consumed")
    func other_windows_untouched() {
        let m = PopoverKeyMonitor.shared
        let savedWindow = m.window
        defer { m.window = savedWindow }
        m.window = nil
        #expect(!m.handle(keyCode: 53, modifiers: [], windowNumber: 42))
        let popover = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10),
                               styleMask: [.borderless], backing: .buffered, defer: true)
        popover.isReleasedWhenClosed = false
        m.window = popover
        // A different window (the TypeSafe login, a sheet): passed through.
        #expect(!m.handle(keyCode: 53, modifiers: [], windowNumber: popover.windowNumber + 1))
        // Not Esc on the popover window itself: passed through too.
        #expect(!m.handle(keyCode: 36, modifiers: [], windowNumber: popover.windowNumber))
        // Plain Esc on the popover window: consumed (closing is a no-op here,
        // no popover is presented in tests).
        #expect(m.handle(keyCode: 53, modifiers: [], windowNumber: popover.windowNumber))
        // ...unless a modal is up.
        m.aboutConfirmationShown = true
        defer { m.aboutConfirmationShown = false }
        #expect(!m.handle(keyCode: 53, modifiers: [], windowNumber: popover.windowNumber))
    }
}
