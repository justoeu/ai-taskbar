import AppKit

/// One `AccountSwitcherView` as the keyboard sees it. A class, so the view
/// can refresh `step` (it captures the current chips and selection) without
/// re-registering.
@MainActor
final class AccountSwitcherHandle {
    var step: (Int) -> Void = { _ in }
}

/// Routes ← / → to an account switcher while the popover is open.
///
/// The home cards stay mounted (disabled) under the Analytics page, so both
/// pages' switchers can be registered at once; only ENABLED ones count. The
/// target is the switcher under the mouse, else the one last used, else the
/// only enabled one. With several and no hint (two multi-account vendors,
/// neither touched), the arrows are left alone rather than guessed.
@MainActor
final class AccountSwitcherKeyboard {
    static let shared = AccountSwitcherKeyboard()

    private struct Entry {
        weak var handle: AccountSwitcherHandle?
        var enabled: Bool
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var hovered: ObjectIdentifier?
    private var lastUsed: ObjectIdentifier?

    func register(_ handle: AccountSwitcherHandle, enabled: Bool) {
        entries[ObjectIdentifier(handle)] = Entry(handle: handle, enabled: enabled)
    }

    func unregister(_ handle: AccountSwitcherHandle) {
        let id = ObjectIdentifier(handle)
        entries[id] = nil
        if hovered == id { hovered = nil }
        if lastUsed == id { lastUsed = nil }
    }

    func setHovered(_ handle: AccountSwitcherHandle, _ isHovered: Bool) {
        let id = ObjectIdentifier(handle)
        if isHovered {
            hovered = id
        } else if hovered == id {
            hovered = nil
        }
    }

    func markUsed(_ handle: AccountSwitcherHandle) {
        lastUsed = ObjectIdentifier(handle)
    }

    /// The switcher the arrows drive right now, if any.
    func target() -> AccountSwitcherHandle? {
        let live = entries.filter { $0.value.enabled && $0.value.handle != nil }
        for id in [hovered, lastUsed].compactMap({ $0 }) {
            if let handle = live[id]?.handle { return handle }
        }
        return live.count == 1 ? live.first?.value.handle : nil
    }

    /// True when a switcher took the step.
    func step(by offset: Int) -> Bool {
        guard let handle = target() else { return false }
        markUsed(handle)
        handle.step(offset)
        return true
    }

    /// ← = -1, → = +1, only without command/option/control/shift. Arrow keys
    /// always carry `.numericPad` and `.function`, so those must not count.
    nonisolated static func offset(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return nil }
        switch keyCode {
        case 123: return -1
        case 124: return 1
        default: return nil
        }
    }
}
