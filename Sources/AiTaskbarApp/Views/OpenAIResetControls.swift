import SwiftUI
import AiTaskbarCore

struct OpenAIResetControls: View {
    @ObservedObject var vm: VendorViewModel
    @ObservedObject var reset: OpenAIResetController

    var body: some View {
        if let path = vm.provider.credentialFileURL {
            VStack(alignment: .leading, spacing: 5) {
                if OpenAIResetController.canOffer(in: vm.state) || reset.pendingAttempt != nil || reset.isBusy {
                    Button {
                        Task { await reset.prepare(path: path) }
                    } label: {
                        Label(L10n.localizedString(reset.isBusy ? "reset_busy"
                              : reset.pendingAttempt == nil ? "reset_button" : "reset_retry"),
                              systemImage: "arrow.counterclockwise.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(reset.isBusy)
                }
                if let message = reset.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
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
            cancelTitle: L10n.localizedString("reset_cancel"),
            onConfirm: {
                Task { if await reset.consume(path: path) { vm.refresh(forceRefresh: true) } }
            },
            onCancel: { reset.cancelConfirmation() })
    }
}
