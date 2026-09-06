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
            .alert(L10n.localizedString("reset_confirm_title"), isPresented: $reset.isConfirming) {
                Button(L10n.localizedString("reset_confirm_button")) {
                    Task {
                        if await reset.consume(path: path) { vm.refresh(forceRefresh: true) }
                    }
                }
                Button(L10n.localizedString("reset_cancel"), role: .cancel) { reset.cancelConfirmation() }
            } message: {
                if let offer = reset.offer {
                    Text(L10n.localizedString("reset_confirm_message", offer.accountLabel, offer.availableCount))
                }
            }
        }
    }
}
