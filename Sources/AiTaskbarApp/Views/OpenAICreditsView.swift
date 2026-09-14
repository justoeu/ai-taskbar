import SwiftUI
import AiTaskbarCore

/// Codex credits block: consumption bar, remaining balance, and the message
/// estimates those credits fund.
///
/// Two things this view deliberately does NOT do:
/// - It never prints a currency symbol. The balance is a quantity; the API
///   sends `"4890.3162520000"` with no symbol at all.
/// - It never collapses the local and cloud message estimates into one line.
///   Codex reports both, they mean different things (CLI vs cloud tasks), and
///   the old code silently showed whichever came first.
struct OpenAICreditsView: View {
    let credits: OpenAICreditsInfo
    let thresholds: ThresholdsConfig

    /// Quantity formatting that follows the app's language, not just the
    /// system's: `String(format: "%.2f")` would hard-code a `.` separator, and
    /// omitting `locale` would print `4,890.32` inside an otherwise Portuguese
    /// card whenever `ui.language` overrides the system locale.
    private static let quantityFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = L10n.effectiveLocale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()

    private static func quantity(_ value: Double) -> String {
        quantityFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            creditsHeadline
            if credits.isFundingRequests {
                notice("credits_funding_now", systemImage: "bolt.fill", tint: .orange)
            }
            // Only claim requests are blocked when the plan is spent too.
            // The overage ceiling alone stops nothing while the plan has room.
            if credits.requestsBlocked {
                notice("credits_overage_reached", systemImage: "exclamationmark.triangle.fill",
                       tint: .red)
            } else if credits.isExhausted {
                notice("credits_exhausted", systemImage: "xmark.circle", tint: .secondary)
            }
            messageEstimates
        }
    }

    /// A bar whenever a denominator exists, otherwise the bare balance.
    /// Showing a 0% bar with no baseline would invent precision we lack.
    @ViewBuilder
    private var creditsHeadline: some View {
        if credits.isUnlimited {
            Label(L10n.localizedString("credits_unlimited"), systemImage: "infinity.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let percent = credits.consumedPercent,
                  let balance = credits.balance, let peak = credits.peakBalance {
            ProviderRowView(
                window: UsageWindow(
                    label: L10n.localizedString("credits_label"),
                    utilizationPercent: percent,
                    resetsAt: nil,
                    detail: L10n.localizedString("credits_remaining_fmt",
                                                 Self.quantity(balance),
                                                 Self.quantity(peak))),
                thresholds: thresholds)
        } else if let balance = credits.balance {
            Label(L10n.localizedString("credits_balance_fmt", Self.quantity(balance)),
                  systemImage: "circle.hexagongrid")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var messageEstimates: some View {
        if let local = credits.localMessages {
            messageLine("credits_local_msgs_fmt", range: local)
        }
        if let cloud = credits.cloudMessages {
            messageLine("credits_cloud_msgs_fmt", range: cloud)
        }
    }

    private func messageLine(_ key: String, range: CreditMessageRange) -> some View {
        Label(L10n.localizedString(key, range.low, range.high), systemImage: "message")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func notice(_ key: String, systemImage: String, tint: Color) -> some View {
        Label(L10n.localizedString(key), systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(tint)
    }
}
