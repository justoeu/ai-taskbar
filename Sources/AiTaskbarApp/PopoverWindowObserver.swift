import AppKit
import SwiftUI

/// The popover's window, once the popover view is in it. Read by
/// `PinnedStatusItemManager` to see whether the popover is really on screen.
@MainActor
final class PopoverWindowHolder {
    static let shared = PopoverWindowHolder()
    weak var window: NSWindow?
    weak var tracker: PopoverWindowObserver.TrackingView?
    private init() {}

    /// Re-reads the window now and reports a change at once, instead of
    /// waiting for the notification. A hide followed by an immediate reopen
    /// (a pinned click on another LLM) can otherwise reach the observer as
    /// no change at all, and the reopen then never counts as an open.
    func resync() {
        tracker?.evaluate(forceHidden: false)
    }

    /// nil while the window is unknown (never opened yet).
    var isWindowShowing: Bool? {
        window.map { PopoverWindowObserver.isShowing($0) }
    }
}

/// Reports the popover window's real visibility. On macOS 27 the
/// MenuBarExtra content stays alive across closes (`onAppear` runs once,
/// `onDisappear` never — measured 2026-11-13 on 27.2.1), so the window is
/// the only signal left. Emits only on change.
struct PopoverWindowObserver: NSViewRepresentable {
    let onVisibilityChange: (Bool) -> Void

    static func isShowing(_ window: NSWindow) -> Bool {
        window.isVisible && window.occlusionState.contains(.visible)
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onVisibilityChange = onVisibilityChange
    }

    final class TrackingView: NSView {
        var onVisibilityChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            lastReported = nil
            guard let window else {
                if PopoverWindowHolder.shared.tracker === self {
                    PopoverWindowHolder.shared.window = nil
                    PopoverWindowHolder.shared.tracker = nil
                }
                return
            }
            PopoverWindowHolder.shared.window = window
            PopoverWindowHolder.shared.tracker = self
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.willCloseNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.evaluate(forceHidden: closing) }
                }
            }
            // Not synchronously: this can run inside a SwiftUI update, and
            // the callback mutates view state.
            DispatchQueue.main.async { [weak self] in self?.evaluate(forceHidden: false) }
        }

        func evaluate(forceHidden: Bool) {
            guard let window else { return }
            let showing = !forceHidden && PopoverWindowObserver.isShowing(window)
            guard showing != lastReported else { return }
            lastReported = showing
            onVisibilityChange?(showing)
        }
        // No deinit cleanup: leaving the window calls viewDidMoveToWindow
        // with nil, which removes the observers (and they hold self weakly).
    }
}

