import SwiftUI

/// One confirmation (or notice) drawn INSIDE the popover window.
///
/// Native `.alert` / `.confirmationDialog` open a separate window; the
/// MenuBarExtra window loses key to it and closes, so the button click never
/// lands and the dialog's "presented" state survives into the next open —
/// the OpenAI reset looked stuck ("Confirm" closed the app, reopening showed
/// the same dialog). About's quit confirmation hit the same thing earlier.
/// Every popover confirmation goes through `ConfirmationCenter` instead.
struct ConfirmationRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var symbol = "questionmark.circle.fill"
    var tint: Color = .accentColor
    let confirmTitle: String
    var isDestructive = false
    /// nil = a notice with a single button (`confirmTitle`).
    var cancelTitle: String?
    var onConfirm: @MainActor () -> Void = {}
    var onCancel: @MainActor () -> Void = {}
}

@MainActor
final class ConfirmationCenter: ObservableObject {
    static let shared = ConfirmationCenter()

    @Published private(set) var request: ConfirmationRequest?

    /// A new request never silently replaces an open one: the old one is
    /// cancelled first, so its state (an OpenAI `isConfirming`, an
    /// unconfirmed OAuth opt-in) is rolled back instead of left stuck.
    func present(_ request: ConfirmationRequest) {
        cancel()
        self.request = request
    }

    /// Runs the confirm action once, after the overlay is gone.
    func confirm() {
        guard let request else { return }
        self.request = nil
        request.onConfirm()
    }

    /// Esc, the dimmed backdrop, the Cancel button, or the popover closing.
    func cancel() {
        guard let request else { return }
        self.request = nil
        request.onCancel()
    }
}

struct ConfirmationOverlay: View {
    let request: ConfirmationRequest
    @ObservedObject var center: ConfirmationCenter

    /// Return confirms only a harmless action. A destructive one (restore
    /// defaults, spending an OpenAI reset) needs a click on the red button,
    /// so a stray or held Return cannot fire it.
    @ViewBuilder
    private var confirmButton: some View {
        let button = Button(role: request.isDestructive ? .destructive : nil) { center.confirm() } label: {
            Text(request.confirmTitle).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(request.isDestructive ? .red : .accentColor)
        .controlSize(.regular)
        if Self.returnConfirms(request) {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }

    static func returnConfirms(_ request: ConfirmationRequest) -> Bool { !request.isDestructive }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { center.cancel() }
                .accessibilityHidden(true)

            VStack(spacing: 16) {
                Image(systemName: request.symbol)
                    .font(.system(size: 36))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(request.tint)

                VStack(spacing: 6) {
                    Text(request.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(request.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    if let cancelTitle = request.cancelTitle {
                        Button { center.cancel() } label: {
                            Text(cancelTitle).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .keyboardShortcut(.cancelAction)
                    }
                    confirmButton
                }
            }
            .padding(20)
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }
}
