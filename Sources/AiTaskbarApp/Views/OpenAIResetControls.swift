import SwiftUI
import AiTaskbarCore

struct OpenAIResetControls: View {
    @ObservedObject var vm: VendorViewModel
    @ObservedObject var reset: OpenAIResetController

    private var buttonTitle: String {
        if reset.isBusy {
            return reset.activity == .applying
                ? L10n.localizedString("reset_applying")
                : L10n.localizedString("reset_busy")
        }
        return reset.pendingAttempt == nil
            ? L10n.localizedString("reset_button")
            : L10n.localizedString("reset_retry")
    }

    var body: some View {
        if let path = vm.provider.credentialFileURL {
            VStack(alignment: .leading, spacing: 6) {
                if OpenAIResetController.canOffer(in: vm.state) || reset.pendingAttempt != nil || reset.isBusy {
                    Button {
                        reset.beginPreparing()
                        Task { await reset.prepare(path: path) }
                    } label: {
                        HStack(spacing: 6) {
                            if reset.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.counterclockwise.circle")
                            }
                            Text(buttonTitle)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(reset.isBusy)
                }

                if reset.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reset.activity == .applying
                                 ? L10n.localizedString("reset_applying_status")
                                 : L10n.localizedString("reset_checking_status"))
                                .font(.caption.weight(.medium))
                            Text(L10n.localizedString("reset_waiting_response"))
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
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
            .task { await reset.restorePending() }
            // In-window, not `.alert`: a native alert window closed the
            // popover and the click never reached "Confirm".
            .onChange(of: reset.isConfirming) { confirming in
                guard confirming else { return }
                ConfirmationCenter.shared.present(Self.confirmation(reset: reset, vm: vm, path: path))
            }
        }
    }

    static func confirmation(reset: OpenAIResetController, vm: VendorViewModel, path: URL) -> ConfirmationRequest {
        ConfirmationRequest(
            title: L10n.localizedString("reset_confirm_title"),
            message: reset.offer.map {
                L10n.localizedString("reset_confirm_message", $0.accountLabel, $0.availableCount)
            } ?? "",
            symbol: "arrow.counterclockwise.circle.fill",
            confirmTitle: L10n.localizedString("reset_confirm_button"),
            // Spends a reset credit: click-only, never the Return key.
            isDestructive: true,
            cancelTitle: L10n.localizedString("reset_cancel"),
            onConfirm: {
                reset.beginConsuming()
                Task { if await reset.consume(path: path) { vm.refresh(forceRefresh: true) } }
            },
            onCancel: { reset.cancelConfirmation() })
    }
}
