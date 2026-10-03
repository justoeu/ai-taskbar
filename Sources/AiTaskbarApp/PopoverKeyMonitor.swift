import AppKit
import SwiftUI

/// What Esc does while the popover is open. Pure, so the rule is tested.
enum PopoverEscape: Equatable {
    /// A modal (pin-limit alert, About's quit confirmation) is up: let the
    /// page's own Esc handler dismiss it.
    case passToModal
    /// Close the whole popover, from any screen.
    case closePopover

    static func action(modalShown: Bool) -> PopoverEscape {
        modalShown ? .passToModal : .closePopover
    }
}

/// Closes the popover on Esc from any screen. SwiftUI's `onExitCommand`
/// alone can't: on the home screen no control holds focus, so Esc reached
/// nothing. A local key monitor sees the key before the view hierarchy, and
/// acts only on events sent to the popover's own window — never the TypeSafe
/// login window or any other.
@MainActor
final class PopoverKeyMonitor {
    static let shared = PopoverKeyMonitor()
    nonisolated static let escapeKeyCode: UInt16 = 53

    weak var window: NSWindow?
    /// Read live, not copied: `store.pinLimitAlert` can stay set across a
    /// close, and macOS 13's `onChange` does not report the initial value.
    weak var store: UsageStore?
    var aboutConfirmationShown = false
    private var monitor: Any?

    var modalShown: Bool { store?.pinLimitAlert != nil || aboutConfirmationShown }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // AppKit calls local monitors on the main thread, but the closure
            // type does not say so; assumeIsolated states it, and only
            // Sendable values are copied in, so nothing non-Sendable crosses.
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let windowNumber = event.windowNumber
            let consumed = MainActor.assumeIsolated {
                PopoverKeyMonitor.shared.handle(keyCode: keyCode, modifiers: modifiers,
                                                windowNumber: windowNumber)
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when the event was consumed.
    func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, windowNumber: Int) -> Bool {
        guard Self.isPlainEscape(keyCode: keyCode, modifiers: modifiers),
              let window, window.windowNumber == windowNumber else { return false }
        switch PopoverEscape.action(modalShown: modalShown) {
        case .passToModal:
            return false
        case .closePopover:
            PinnedStatusItemManager.shared.closeMainPopover()
            return true
        }
    }

    nonisolated static func isPlainEscape(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == escapeKeyCode
            && modifiers.intersection([.command, .option, .control, .shift]).isEmpty
    }
}

/// Reports the hosting window of the popover's content.
struct PopoverWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
