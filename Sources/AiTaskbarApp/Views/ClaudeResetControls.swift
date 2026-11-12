import SwiftUI
import AiTaskbarCore
import AiTaskbarProviders

/// One button per reset kind the account can use right now (Fable, weekly,
/// 5-hour, full), under the same rule as the OpenAI reset. Each spend goes
/// through an in-window, click-only confirmation.
struct ClaudeResetControls: View {
    @ObservedObject var vm: VendorViewModel
    @ObservedObject var reset: ClaudeResetController

    var body: some View {
        let offers = ClaudeResetController.offers(in: vm.state)
        VStack(alignment: .leading, spacing: 6) {
            if let pending = reset.pendingAttempt {
                button(kind: pending.kind,
                       title: L10n.localizedString("claude_reset_retry", ClaudeResetController.kindName(pending.kind)))
            } else {
                ForEach(offers) { offer in
                    button(kind: offer.kind,
                           title: L10n.localizedString("claude_reset_button",
                                                       ClaudeResetController.kindName(offer.kind),
                                                       offer.resetsLeft))
                }
            }

            if reset.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reset.activity == .applying
                             ? L10n.localizedString("claude_reset_applying_status")
                             : L10n.localizedString("claude_reset_checking_status"))
                            .font(.caption.weight(.medium))
                        Text(L10n.localizedString("claude_reset_waiting_response"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
                .transition(.opacity)
            } else if let message = reset.message {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: reset.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(reset.isSuccess ? Color.green : Color.orange)
                        .font(.caption)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: reset.isBusy)
        .animation(.easeInOut(duration: 0.2), value: reset.message)
        // In-window, not `.alert`: a native alert closes the popover.
        .onChange(of: reset.isConfirming) { confirming in
            guard confirming else { return }
            ConfirmationCenter.shared.present(Self.confirmation(reset: reset, vm: vm))
        }
    }

    private func button(kind: ClaudeResetKind, title: String) -> some View {
        Button {
            reset.beginPreparing(kind: kind)
            Task { await reset.prepare(kind: kind) }
        } label: {
            HStack(spacing: 6) {
                if reset.isBusy && reset.activeKind == kind {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.counterclockwise.circle")
                }
                Text(reset.isBusy && reset.activeKind == kind
                     ? L10n.localizedString(reset.activity == .applying ? "reset_applying" : "reset_busy")
                     : title)
            }
        }
        .buttonStyle(.bordered)
        .disabled(reset.isBusy)
    }

    static func confirmation(reset: ClaudeResetController, vm: VendorViewModel) -> ConfirmationRequest {
        let account = vm.accountLabel ?? vm.vendorId.displayName
        return ConfirmationRequest(
            title: L10n.localizedString("claude_reset_confirm_title"),
            message: reset.attempt.map {
                L10n.localizedString("claude_reset_confirm_message",
                                     account,
                                     ClaudeResetController.kindName($0.kind),
                                     $0.grantLabel,
                                     $0.resetsLeft)
            } ?? "",
            symbol: "arrow.counterclockwise.circle.fill",
            confirmTitle: L10n.localizedString("reset_confirm_button"),
            // Spends a reset: click-only, never the Return key.
            isDestructive: true,
            cancelTitle: L10n.localizedString("reset_cancel"),
            onConfirm: {
                reset.beginConsuming()
                Task { if await reset.consume() { vm.refresh(forceRefresh: true) } }
            },
            onCancel: { reset.cancelConfirmation() })
    }
}
