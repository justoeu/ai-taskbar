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
struct AccountSwitcherView: View {
    let chips: [AccountChip]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        let index = chips.firstIndex(where: { $0.id == selectedID }) ?? 0
        HStack(spacing: 6) {
            arrow("chevron.left", help: "account_previous_help") { step(from: index, by: -1) }
            HStack(spacing: 4) {
                ForEach(chips) { chip in
                    Button { onSelect(chip.id) } label: { dot(chip, selected: chip.id == selectedID) }
                        .buttonStyle(.plain)
                        .help(chip.name)
                }
            }
            Text(chips.indices.contains(index) ? chips[index].name : "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            arrow("chevron.right", help: "account_next_help") { step(from: index, by: 1) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.localizedString("account_switcher_accessibility_fmt",
                                                 chips.indices.contains(index) ? chips[index].name : "",
                                                 index + 1, chips.count))
    }

    private func step(from index: Int, by offset: Int) {
        guard !chips.isEmpty else { return }
        let count = chips.count
        onSelect(chips[((index + offset) % count + count) % count].id)
    }

    private func arrow(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(L10n.localizedString(help))
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
