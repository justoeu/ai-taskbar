import SwiftUI
import AiTaskbarCore

/// One position of an `AccountSwitcherView`.
public struct AccountChip: Identifiable, Equatable {
    public let id: String
    public let name: String
    /// An account the user is NOT looking at that needs a look (error,
    /// Keychain access, expired login, usage at the warning threshold).
    public let needsAttention: Bool

    public init(id: String, name: String, needsAttention: Bool = false) {
        self.id = id
        self.name = name
        self.needsAttention = needsAttention
    }
}

/// ‹ • • name › — the lateral navigation between the accounts grouped in one
/// card (SDD-claude-multi-account §6.3). Arrow buttons wrap around; each dot
/// selects its account directly. A dot ringed in orange marks a hidden
/// account that needs attention, so a spent account never hides behind the
/// switcher.
///
/// Hovering an arrow highlights it and turns the name into the account it
/// leads to ("← main"): a bare chevron with a slow tooltip read as nothing.
/// ← / → drive it from the keyboard (`AccountSwitcherKeyboard`).
struct AccountSwitcherView: View {
    let chips: [AccountChip]
    let selectedID: String
    let onSelect: (String) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var handle = AccountSwitcherHandle()
    @State private var hoveredArrow: Int?

    var body: some View {
        let index = currentIndex
        HStack(spacing: 6) {
            arrow(-1)
            HStack(spacing: 4) {
                ForEach(chips) { chip in
                    Button { select(chip.id) } label: { dot(chip, selected: chip.id == selectedID) }
                        .buttonStyle(.plain)
                        .help(chip.name)
                }
            }
            nameLabel(index: index)
            arrow(1)
            Spacer(minLength: 0)
        }
        .onHover { AccountSwitcherKeyboard.shared.setHovered(handle, $0) }
        .onAppear {
            refreshHandle()
            AccountSwitcherKeyboard.shared.register(handle, enabled: isEnabled)
        }
        .onDisappear {
            AccountSwitcherKeyboard.shared.unregister(handle)
            if hoveredArrow != nil { NSCursor.pop() }
            hoveredArrow = nil
        }
        .onChange(of: isEnabled) { AccountSwitcherKeyboard.shared.register(handle, enabled: $0) }
        .onChange(of: selectedID) { _ in refreshHandle() }
        .onChange(of: chips) { _ in refreshHandle() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.localizedString("account_switcher_accessibility_fmt",
                                                 chips.indices.contains(index) ? chips[index].name : "",
                                                 index + 1, chips.count))
    }

    private var currentIndex: Int { chips.firstIndex(where: { $0.id == selectedID }) ?? 0 }

    /// Where an arrow leads from the current account, wrapping around.
    static func destination(from index: Int, by offset: Int, count: Int) -> Int {
        ((index + offset) % count + count) % count
    }

    private func destinationChip(_ offset: Int) -> AccountChip? {
        guard !chips.isEmpty else { return nil }
        return chips[Self.destination(from: currentIndex, by: offset, count: chips.count)]
    }

    private func select(_ id: String) {
        AccountSwitcherKeyboard.shared.markUsed(handle)
        onSelect(id)
    }

    /// The keyboard calls the latest selection, not the one at first render.
    private func refreshHandle() {
        let chips = chips
        let index = currentIndex
        let onSelect = onSelect
        handle.step = { offset in
            guard !chips.isEmpty else { return }
            onSelect(chips[Self.destination(from: index, by: offset, count: chips.count)].id)
        }
    }

    @ViewBuilder
    private func nameLabel(index: Int) -> some View {
        if let offset = hoveredArrow, let target = destinationChip(offset) {
            // Preview of the arrow's destination, arrow on the side it points.
            HStack(spacing: 3) {
                if offset < 0 { Image(systemName: "arrow.left") }
                Text(target.name)
                if offset > 0 { Image(systemName: "arrow.right") }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
            Text(chips.indices.contains(index) ? chips[index].name : "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func arrow(_ offset: Int) -> some View {
        let hovered = hoveredArrow == offset
        let helpKey = offset < 0 ? "account_previous_help_fmt" : "account_next_help_fmt"
        return Button {
            guard let target = destinationChip(offset) else { return }
            select(target.id)
        } label: {
            Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                .font(.caption2.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(hovered ? 0.18 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(hovered ? Color.accentColor : Color.secondary)
        .help(L10n.localizedString(helpKey, destinationChip(offset)?.name ?? ""))
        .onHover { inside in
            if inside, hoveredArrow == nil { NSCursor.pointingHand.push() }
            if !inside, hoveredArrow == offset { NSCursor.pop() }
            hoveredArrow = inside ? offset : (hoveredArrow == offset ? nil : hoveredArrow)
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func dot(_ chip: AccountChip, selected: Bool) -> some View {
        Circle()
            .fill(selected ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(Color.orange, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
                    .opacity(chip.needsAttention && !selected ? 1 : 0)
            )
            .frame(width: 12, height: 12)
            .contentShape(Rectangle())
    }
}

extension VendorViewModel {
    /// The account's display name: its label, or "main" for the default.
    var accountDisplayName: String {
        accountLabel ?? L10n.localizedString("account_default_label")
    }

    /// Whether a hidden account in a switcher deserves a look.
    func needsAttention(thresholds: ThresholdsConfig) -> Bool {
        switch state {
        case .failed(let error, _):
            return !error.isDisabled
        case .ok(let outcome):
            if needsReauth || state.isKeychainACLBlocked { return true }
            return outcome.snapshot.maxUtilization >= thresholds.warning
        default:
            return false
        }
    }
}
