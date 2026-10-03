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
        #expect(!PopoverKeyMonitor.isPlainEscape(keyCode: 36, modifiers: []))
    }

    @MainActor
    @Test("either modal counts as shown")
    func modal_state() {
        let m = PopoverKeyMonitor.shared
        defer { m.pinLimitAlertShown = false; m.aboutConfirmationShown = false }
        #expect(!m.modalShown)
        m.pinLimitAlertShown = true
        #expect(m.modalShown)
        m.pinLimitAlertShown = false
        m.aboutConfirmationShown = true
        #expect(m.modalShown)
    }
}
