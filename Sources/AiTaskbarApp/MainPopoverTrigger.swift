import AppKit
import AiTaskbarCore

/// Opens or closes the main `MenuBarExtra` popover from code (a pinned item's
/// click, Esc).
///
/// Measured on macOS 27.2.1 (2026-11-13) with a standalone MenuBarExtra probe:
/// the main item is an `NSSceneStatusItem` and a real click reaches the app as
/// a scene action, not as a mouse event. Its `NSStatusBarButton` has NO
/// target/action, and `performClick`, `accessibilityPerformPress`, a
/// synthesized mouseDown sent to its window or `button.mouseDown(with:)` all
/// leave the popover closed — which is how clicking a pinned percentage
/// stopped opening the app. What works is the status item's own expanded
/// interface session:
///
/// - `_requestExpandedInterfaceSession` opens it (it never closes it);
/// - `_endExpandedInterfaceSession:animate:` with a nil session closes it in
///   sync: `onDisappear` runs, a later request reopens it, and the next real
///   click on the icon still toggles correctly. `window.close()`,
///   `orderOut`, `NSApp.hide` and `NSApp.deactivate` were tried too: the
///   first three hide the window without telling MenuBarExtra (it then never
///   reopens), the last does nothing.
///
/// Backward compatible by construction: both calls are private, so they are
/// used only on macOS 27+, only when the button has no target/action, and
/// only after `responds(to:)` confirms them. On macOS 13–26 the route is
/// exactly the previous one: target/action when present, else `performClick`.
@MainActor
enum MainPopoverTrigger {
    enum Intent: Equatable {
        case open
        case close
    }

    enum Route: Equatable {
        /// macOS ≤ 26: SwiftUI's button carries the toggle as target/action.
        case buttonAction
        /// macOS 27+: the scene status item's expanded interface session.
        case sceneSession
        case performClick
    }

    /// macOS 27 is where status items became scene items and the old
    /// trigger stopped working; older systems keep the old route.
    nonisolated static var isSceneStatusItemOS: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )
    }

    /// Whether the popover content dissolves in on open. macOS 27 keeps the
    /// view alive and shows the window ~20 ms BEFORE any open signal reaches
    /// the app (measured 2026-11-13: occlusion/key notifications after the
    /// window is on screen), so hiding the content at close and fading it
    /// back at open drew the window half empty, then blank, then filled —
    /// the flicker reported on 27.2.1. There the system presents the window
    /// and the content stays opaque; older systems keep the dissolve.
    nonisolated static func dissolvesContentOnOpen(isSceneStatusItemOS: Bool) -> Bool {
        !isSceneStatusItemOS
    }

    nonisolated static func route(
        hasTargetAction: Bool,
        supportsSceneSession: Bool,
        isSceneStatusItemOS: Bool
    ) -> Route {
        if hasTargetAction { return .buttonAction }
        if isSceneStatusItemOS, supportsSceneSession { return .sceneSession }
        return .performClick
    }

    nonisolated static let statusItemSelector = NSSelectorFromString("_statusItem")
    nonisolated static let requestSelector = NSSelectorFromString("_requestExpandedInterfaceSession")
    nonisolated static let endSelector = NSSelectorFromString("_endExpandedInterfaceSession:animate:")

    /// The button's status item when it supports BOTH session calls; nil
    /// otherwise, so a half-present private API never opens what it cannot
    /// close.
    static func sceneStatusItem(of button: NSStatusBarButton) -> NSObject? {
        guard button.responds(to: statusItemSelector),
              let item = button.perform(statusItemSelector)?.takeUnretainedValue() as? NSObject,
              item.responds(to: requestSelector),
              item.responds(to: endSelector)
        else { return nil }
        return item
    }

    static func trigger(_ button: NSStatusBarButton, intent: Intent) {
        // Not even probed before macOS 27.
        let sceneItem = isSceneStatusItemOS ? sceneStatusItem(of: button) : nil
        let hasTargetAction = button.target != nil && button.action != nil
        switch route(
            hasTargetAction: hasTargetAction,
            supportsSceneSession: sceneItem != nil,
            isSceneStatusItemOS: isSceneStatusItemOS
        ) {
        case .buttonAction:
            if let action = button.action {
                NSApplication.shared.sendAction(action, to: button.target, from: button)
            }
        case .sceneSession:
            guard let sceneItem else { return }
            switch intent {
            case .open:
                sceneItem.perform(requestSelector)
            case .close:
                typealias EndSession = @convention(c) (AnyObject, Selector, AnyObject?, Bool) -> Void
                let end = unsafeBitCast(sceneItem.method(for: endSelector), to: EndSession.self)
                end(sceneItem, endSelector, nil, true)
            }
        case .performClick:
            if isSceneStatusItemOS {
                AppLog.pinning.error("main status button has no action and no scene session; falling back to performClick")
            }
            button.performClick(nil)
        }
    }
}
