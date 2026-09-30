import SwiftUI

/// "Sync LLM order" checkbox + help popover shared by the Analytics and
/// Service Status screens. On: the screen follows the home screen's order.
/// Off: the screen keeps its own order, changed with ↑/↓ on each card.
struct VendorOrderSyncBar: View {
    @Binding var isOn: Bool
    @State private var showHelp = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isOn) {
                Text(L10n.localizedString("sync_vendor_order"))
                    .font(.callout.weight(.medium))
            }
            .toggleStyle(.checkbox)

            Button {
                showHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.localizedString("sync_vendor_order_help"))
            .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Color.accentColor)
                        Text(L10n.localizedString("sync_vendor_order"))
                            .font(.headline)
                    }
                    Text(L10n.localizedString("sync_vendor_order_help"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(width: 280)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }
}
