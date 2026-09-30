import SwiftUI
import AppKit
import AiTaskbarCore

/// TypeSafe (Jev) card body, laid out like the other cards' window rows:
/// title left, monospaced value right, a bar, then one secondary detail line.
/// There is no quota: the bar is the share of purchased credit already spent,
/// drawn only when the console reports what was purchased.
struct TypeSafeCardView: View {
    let snapshot: TypeSafeSnapshot
    var thresholds: ThresholdsConfig = .init()
    @ObservedObject private var login = TypeSafeLoginController.shared

    /// Money follows the app language (`ui.language`), not only the system's.
    private static let usdFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = L10n.effectiveLocale
        f.numberStyle = .currency
        f.currencyCode = "USD"
        return f
    }()

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = L10n.effectiveLocale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = L10n.effectiveLocale
        f.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        return f
    }()

    static func usd(_ value: Double) -> String {
        usdFormatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            consoleNotice
            if let billing = snapshot.billing {
                balanceRow(billing)
                spendRow(billing)
            }
            if let usage = snapshot.usage {
                usageGrid(usage)
            }
            if let error = login.lastError {
                notice(error, systemImage: "exclamationmark.triangle", tint: .orange)
            }
            keyFooter
        }
    }

    // MARK: rows

    private func balanceRow(_ b: TypeSafeBilling) -> some View {
        let used = Self.usedPercent(b)
        return VStack(alignment: .leading, spacing: 4) {
            valueHeader(L10n.localizedString("typesafe_balance"), Self.usd(b.balanceUSD))
            if let used {
                ProgressView(value: min(max(used, 0), 100), total: 100)
                    .progressViewStyle(.linear)
                    .tint(SeverityColor.tint(forPercent: used, thresholds: thresholds))
            }
            detail(Self.balanceDetail(b, usedPercent: used))
        }
        .padding(.vertical, 2)
    }

    private func spendRow(_ b: TypeSafeBilling) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            valueHeader(L10n.localizedString("typesafe_spent_cycle"), Self.usd(b.spentUSD))
            let parts = [Self.cycleName(b.cycleLabel),
                         b.cycleEndsInDays.map { L10n.localizedString("typesafe_cycle_closes_fmt", $0) },
                         Self.planLabel(b.plan)].compactMap { $0 }
            if !parts.isEmpty { detail(parts.joined(separator: " · ")) }
        }
        .padding(.vertical, 2)
    }

    private func usageGrid(_ u: TypeSafeUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.localizedString("typesafe_tokens"))
                .font(.subheadline.weight(.medium))
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 2) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1).gridColumnAlignment(.leading)
                    columnTitle("typesafe_today")
                    columnTitle("typesafe_week")
                }
                usageLine("typesafe_input", u.todayInputTokens, u.weekInputTokens)
                usageLine("typesafe_output", u.todayOutputTokens, u.weekOutputTokens)
                usageLine("typesafe_requests", u.todayRequests, u.weekRequests)
            }
        }
        .padding(.vertical, 2)
    }

    private func usageLine(_ key: String, _ today: Int, _ week: Int) -> some View {
        GridRow {
            Text(L10n.localizedString(key))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(Self.count(today)).monospacedDigit()
            Text(Self.count(week)).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func columnTitle(_ key: String) -> some View {
        Text(L10n.localizedString(key))
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    /// Key state and models, quiet at the bottom: it is the heartbeat, not
    /// the news. The console link is the header's own external-link button.
    private var keyFooter: some View {
        Label(L10n.localizedString("typesafe_key_models_fmt",
                                   snapshot.models.map(\.name).joined(separator: ", ")),
              systemImage: "checkmark.seal")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func valueHeader(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(value).font(.subheadline.monospacedDigit())
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: console state

    /// What the console part can show right now, and the one action for it.
    @ViewBuilder
    private var consoleNotice: some View {
        switch snapshot.console {
        case .notConnected:
            VStack(alignment: .leading, spacing: 4) {
                notice(L10n.localizedString("typesafe_console_connect_hint"), systemImage: "info.circle")
                signInButton("typesafe_console_sign_in")
            }
        case .expired:
            VStack(alignment: .leading, spacing: 4) {
                notice(L10n.localizedString("typesafe_console_expired"), systemImage: "exclamationmark.triangle",
                       tint: .orange)
                signInButton("typesafe_console_sign_in_again")
            }
        case .unavailable:
            notice(L10n.localizedString(snapshot.billing == nil && snapshot.usage == nil
                                        ? "typesafe_console_unavailable"
                                        : "typesafe_console_unavailable_last"),
                   systemImage: "icloud.slash")
        case .connected(let expiresAt):
            if let expiresAt, TypeSafeConsoleSession.isExpiringSoon(expiresAt: expiresAt, now: .now) {
                VStack(alignment: .leading, spacing: 4) {
                    notice(L10n.localizedString("typesafe_console_expires_fmt",
                                                Self.dateFormatter.string(from: expiresAt)),
                           systemImage: "clock.badge.exclamationmark", tint: .orange)
                    signInButton("typesafe_console_sign_in_again")
                }
            }
        }
    }

    private func notice(_ text: String, systemImage: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signInButton(_ key: String) -> some View {
        Button {
            login.signIn()
        } label: {
            Label(L10n.localizedString(key), systemImage: "person.crop.circle.badge.checkmark")
                .font(.caption)
        }
        .buttonStyle(.link)
        .disabled(login.isSigningIn)
    }

    // MARK: formatting (pure, tested)

    /// Share of purchased credit already spent, or nil when the console does
    /// not report a purchase to measure against (no invented denominator).
    static func usedPercent(_ b: TypeSafeBilling) -> Double? {
        guard let purchased = b.purchasedUSD, purchased > 0, b.balanceUSD.isFinite else { return nil }
        return min(max((purchased - b.balanceUSD) / purchased * 100, 0), 100)
    }

    /// "0% usado de US$ 30,00 · expira em 28 de set. de 2027".
    static func balanceDetail(_ b: TypeSafeBilling, usedPercent: Double?) -> String {
        var parts: [String] = []
        if let usedPercent, let purchased = b.purchasedUSD {
            parts.append(L10n.localizedString("typesafe_used_of_fmt", PercentText.format(usedPercent), usd(purchased)))
        }
        if let first = b.credits.first {
            parts.append(L10n.localizedString("typesafe_expires_fmt", dateFormatter.string(from: first.expiresAt)))
        }
        if b.credits.count > 1 {
            parts.append(L10n.localizedString("typesafe_more_credits_fmt", b.credits.count - 1))
        }
        return parts.joined(separator: " · ")
    }

    /// Exact below 100k ("1.521"), compact above ("250k", "2,7M") — a token
    /// count is read at a glance, and a rounded "2k" hid real small numbers.
    static func count(_ n: Int) -> String {
        func scaled(_ divisor: Double, _ suffix: String, decimals: Int) -> String {
            let f = NumberFormatter()
            f.locale = L10n.effectiveLocale
            f.numberStyle = .decimal
            f.maximumFractionDigits = decimals
            return (f.string(from: NSNumber(value: Double(n) / divisor)) ?? "\(n)") + suffix
        }
        switch n {
        case ..<100_000: return countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
        case ..<999_500: return scaled(1e3, "k", decimals: 0)
        case ..<999_500_000: return scaled(1e6, "M", decimals: 1)
        default: return scaled(1e9, "B", decimals: 1)
        }
    }

    /// The console labels the cycle in English ("September 2026"); render it
    /// in the app language. Anything else passes through unchanged.
    static func cycleName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "MMMM yyyy"
        guard let date = parse.date(from: raw) else { return raw }
        let out = DateFormatter()
        out.locale = L10n.effectiveLocale
        out.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return out.string(from: date)
    }

    /// Known plan ids are localized; others become "Title Case".
    static func planLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw {
        case "pay_as_you_go": return L10n.localizedString("typesafe_plan_payg")
        case "free_plan": return L10n.localizedString("typesafe_plan_free")
        default:
            return raw.split(whereSeparator: { $0 == "_" || $0 == "-" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }
}
