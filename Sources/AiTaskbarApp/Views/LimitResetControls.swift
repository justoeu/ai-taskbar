import SwiftUI
import AiTaskbarCore
import AiTaskbarProviders

/// One button per reset kind the account can use right now, under the same
/// rule for every vendor (`LimitResetController`). Each spend goes through
/// an in-window, click-only confirmation.
struct LimitResetControls<Attempt: LimitResetAttempting, Receipt: Sendable>: View {
    struct Option: Identifiable {
        let kind: Attempt.Kind
        let title: String
        var id: Attempt.Kind { kind }
    }

    /// A vendor's wording and offers.
    @MainActor
    struct Presentation {
        let options: @MainActor (VendorViewModel.State) -> [Option]
        let retryTitle: @MainActor (Attempt.Kind) -> String
        let checkingStatus: String
        let applyingStatus: String
        let waitingResponse: String
        /// How the vendor's resets work, shown on hover next to the buttons.
        let info: String?
        let confirmTitle: String
        /// The confirmation's body for the account label and the attempt.
        let confirmMessage: @MainActor (String, Attempt) -> String
    }

    @ObservedObject var vm: VendorViewModel
    @ObservedObject var reset: LimitResetController<Attempt, Receipt>
    let presentation: Presentation

    var body: some View {
        let options = presentation.options(vm.state)
        VStack(alignment: .leading, spacing: 6) {
            if let pending = reset.pendingAttempt {
                row(first: true) { button(kind: pending.kind, title: presentation.retryTitle(pending.kind)) }
            } else {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    row(first: index == 0) { button(kind: option.kind, title: option.title) }
                }
            }

            if reset.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reset.activity == .applying ? presentation.applyingStatus : presentation.checkingStatus)
                            .font(.caption.weight(.medium))
                        Text(presentation.waitingResponse)
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
            ConfirmationCenter.shared.present(Self.confirmation(reset: reset, vm: vm, presentation: presentation))
        }
    }

    /// The first button carries the info mark, when the vendor has one.
    private func row<Content: View>(first: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
            if first, let info = presentation.info {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .help(info)
                    .accessibilityLabel(info)
            }
        }
    }

    private func button(kind: Attempt.Kind, title: String) -> some View {
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

    static func confirmation(reset: LimitResetController<Attempt, Receipt>, vm: VendorViewModel,
                             presentation: Presentation) -> ConfirmationRequest {
        let account = vm.accountLabel ?? vm.vendorId.displayName
        return ConfirmationRequest(
            title: presentation.confirmTitle,
            message: reset.attempt.map { presentation.confirmMessage(account, $0) } ?? "",
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

extension LimitResetControls.Presentation where Attempt == ClaudeLimitResetAttempt, Receipt == ClaudeLimitResetReceipt {
    /// Fable, weekly, 5-hour and full resets of one Claude account.
    static var claude: Self {
        Self(
            options: { state in
                ClaudeResetController.offers(in: state).map {
                    LimitResetControls.Option(kind: $0.kind,
                           title: L10n.localizedString("claude_reset_button",
                                                       ClaudeResetController.kindName($0.kind), $0.resetsLeft))
                }
            },
            retryTitle: { L10n.localizedString("claude_reset_retry", ClaudeResetController.kindName($0)) },
            checkingStatus: L10n.localizedString("claude_reset_checking_status"),
            applyingStatus: L10n.localizedString("claude_reset_applying_status"),
            waitingResponse: L10n.localizedString("claude_reset_waiting_response"),
            info: nil,
            confirmTitle: L10n.localizedString("claude_reset_confirm_title"),
            confirmMessage: { account, attempt in
                L10n.localizedString("claude_reset_confirm_message", account,
                                     ClaudeResetController.kindName(attempt.kind),
                                     attempt.grantLabel, attempt.resetsLeft)
            })
    }
}

extension LimitResetControls.Presentation where Attempt == ZAILimitResetAttempt, Receipt == ZAILimitResetReceipt {
    /// The console's "Reset Quota": 5-hour and weekly resets.
    static var zai: Self {
        Self(
            options: { state in
                ZAIResetController.offers(in: state).map {
                    LimitResetControls.Option(kind: $0.kind,
                           title: L10n.localizedString("zai_reset_button",
                                                       ZAIResetController.kindName($0.kind), $0.resetsLeft))
                }
            },
            retryTitle: { L10n.localizedString("zai_reset_retry", ZAIResetController.kindName($0)) },
            checkingStatus: L10n.localizedString("zai_reset_checking_status"),
            applyingStatus: L10n.localizedString("zai_reset_applying_status"),
            waitingResponse: L10n.localizedString("zai_reset_waiting_response"),
            info: L10n.localizedString("zai_reset_info"),
            confirmTitle: L10n.localizedString("zai_reset_confirm_title"),
            confirmMessage: { account, attempt in
                L10n.localizedString(attempt.kind == .weekly ? "zai_reset_confirm_message_weekly"
                                                             : "zai_reset_confirm_message_five_hour",
                                     account,
                                     ZAIResetController.kindName(attempt.kind),
                                     Self.expiry(attempt.expiresAt),
                                     attempt.resetsLeft)
            })
    }

    /// The record's expiry day, localized; the server's text when it is not
    /// a plain date; a dash when absent.
    static func expiry(_ raw: String?) -> String {
        guard let raw else { return "—" }
        guard let date = ZAIResetGrant.expiryDate(raw) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = L10n.effectiveLocale
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
