import AppKit

/// One `AccountSwitcherView` as the keyboard sees it: the switcher's CURRENT
/// accounts, selection and action, refreshed on every render. The view used
/// to rebuild a captured closure from `onChange(of: selectedID)`, but on
/// macOS 13 that action runs with the PREVIOUS view value, so after a click
/// the closure still held the old selection and → re-selected the account
/// already shown — the keys looked dead (reproduced: click ›, press →, no
/// change). Resolving the destination at key time from live state cannot go
/// stale.
@MainActor
final class AccountSwitcherHandle {
    private(set) var ids: [String] = []
    private(set) var selectedID = ""
    private var onSelect: (String) -> Void = { _ in }

    func update(ids: [String], selectedID: String, onSelect: @escaping (String) -> Void) {
        self.ids = ids
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    /// Selects the account `offset` positions away, wrapping around.
    func step(_ offset: Int) {
        guard !ids.isEmpty else { return }
        let index = ids.firstIndex(of: selectedID) ?? 0
        onSelect(ids[AccountSwitcherView.destination(from: index, by: offset, count: ids.count)])
    }
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
