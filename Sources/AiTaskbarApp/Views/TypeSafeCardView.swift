import SwiftUI
import AppKit
import AiTaskbarCore

/// TypeSafe (Jev) card body. There is no quota to draw: the card states what
/// the API key can reach and, when a console session is connected, the
/// console's own billing numbers — never a percentage or a reset.
struct TypeSafeCardView: View {
    let snapshot: TypeSafeSnapshot

    static let consoleUsageURL = URL(string: "https://console.typesafe.ai/usage")!

    /// Money follows the app language (`ui.language`), not only the system's.
    private static let usdFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = L10n.effectiveLocale
        f.numberStyle = .currency
        f.currencyCode = "USD"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = L10n.effectiveLocale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func usd(_ value: Double) -> String {
        usdFormatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L10n.localizedString("typesafe_key_ok_fmt", snapshot.modelCount),
                  systemImage: "checkmark.seal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !snapshot.models.isEmpty {
                Text(snapshot.models.map(\.name).joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let updated = snapshot.lastUpdated {
                Text(L10n.localizedString("typesafe_updated_fmt", Self.dateFormatter.string(from: updated)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let billing = snapshot.billing {
                billingRows(billing)
            } else {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.localizedString("typesafe_no_usage_api"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            Button {
                NSWorkspace.shared.open(Self.consoleUsageURL)
            } label: {
                Label(L10n.localizedString("typesafe_open_console"), systemImage: "arrow.up.right.square")
                    .font(.caption)
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func billingRows(_ b: TypeSafeBilling) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(L10n.localizedString("typesafe_balance_fmt", Self.usd(b.balanceUSD)),
                  systemImage: "dollarsign.circle")
            Label(b.cycleLabel.map { L10n.localizedString("typesafe_spent_cycle_fmt", Self.usd(b.spentUSD), $0) }
                    ?? L10n.localizedString("typesafe_spent_fmt", Self.usd(b.spentUSD)),
                  systemImage: "chart.bar")
            if let plan = Self.planLabel(b.plan) {
                Label(L10n.localizedString("typesafe_plan_fmt", plan), systemImage: "tag")
            }
            if let days = b.cycleEndsInDays, days >= 0 {
                Label(L10n.localizedString("typesafe_cycle_ends_fmt", days), systemImage: "calendar")
            }
            ForEach(Array(b.credits.prefix(3).enumerated()), id: \.offset) { _, credit in
                Label(L10n.localizedString("typesafe_credit_fmt",
                                           Self.usd(credit.remainingUSD),
                                           Self.usd(credit.amountUSD),
                                           Self.dateFormatter.string(from: credit.expiresAt)),
                      systemImage: "ticket")
            }
            if b.credits.count > 3 {
                Text(L10n.localizedString("typesafe_more_credits_fmt", b.credits.count - 3))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// `pay_as_you_go` → "Pay As You Go", `free_plan` → "Free". Display only.
    static func planLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw == "free_plan" { return "Free" }
        return raw.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
