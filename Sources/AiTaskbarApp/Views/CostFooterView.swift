import SwiftUI
import AiTaskbarCore

/// Isolated observer for the shared `CostEstimator`. Lives in its own view so
/// a `cost.refresh()` (every ≥60 s, flipping `isLoading` / `byVendor` /
/// `lastComputedAt`) re-renders **only** the per-vendor cost footer, not the
/// entire `VendorSectionView`. Vendors without their own local scanner can
/// still render a separately attributed opencode breakdown.
public struct CostFooterView: View {
    private let vendorId: VendorId
    @ObservedObject private var cost: CostEstimator

    public init(vendorId: VendorId, cost: CostEstimator) {
        self.vendorId = vendorId
        self.cost = cost
    }

    public var body: some View {
        let estimate = cost.byVendor[vendorId]
        let opencodeScan = cost.opencode[vendorId]
        let hasData = estimate?.hasDisplayData == true
        let supportsLocal = CostEstimator.supportedVendors.contains(vendorId)
        // Render the footer when we already have data, OR while we're loading
        // for a vendor that the local scanners cover. Otherwise (OpenRouter,
        // Z.AI, Kimi, DeepSeek without data), stay hidden.
        if hasData, let estimate {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Label(Self.costText(
                        amount: estimate.usdToday,
                        availability: Self.costAvailability(
                            breakdown: estimate.modelBreakdownToday,
                            unpricedModels: estimate.unpricedModelsToday),
                        completeKey: "today_cost_fmt",
                        partialKey: "today_cost_partial_fmt",
                        unavailableKey: "today_cost_unavailable"),
                          systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label(Self.costText(
                        amount: estimate.usdLast7Days,
                        availability: Self.costAvailability(
                            breakdown: estimate.modelBreakdownLast7Days,
                            unpricedModels: estimate.unpricedModelsLast7Days),
                        completeKey: "weekly_cost_fmt",
                        partialKey: "weekly_cost_partial_fmt",
                        unavailableKey: "weekly_cost_unavailable"),
                          systemImage: "chart.bar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if estimate.isApproximate {
                        L10n.text("approximate_short")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .help(estimate.note ?? L10n.localizedString("approximate_help"))
                    }
                }
                modelBreakdownDetailed(for: estimate)
                if let scan = opencodeScan, !scan.isEmpty {
                    opencodeSection(scan)
                }
            }
        } else if let scan = opencodeScan, !scan.isEmpty {
            // The vendor has no local CLI scanner of its own (xAI), so there is
            // no cost estimate to hang this off. Its usage still arrived
            // through opencode and is still worth attributing, so the footer
            // renders for the breakdown alone.
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                opencodeSection(scan)
            }
        } else if supportsLocal && cost.isLoading {
            Divider()
            modelBreakdownLoading
        }
    }

    /// Placeholder shown when the cost scanner is running and we don't have
    /// any prior data for this vendor yet (e.g. the first launch).
    @ViewBuilder
    private var modelBreakdownLoading: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                L10n.text("models_label")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
                Spacer(minLength: 6)
            }
            HStack(spacing: 4) {
                Text("•")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                L10n.text("loading")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 4)
        }
        .padding(.leading, 2)
    }

    /// Combined breakdown showing both today and the 7-day window. Today
    /// might only have 1 model (what you used right now); 7d typically has
    /// more (everything in your recent history). Showing both removes the
    /// "where did the $7k come from?" mystery.
    @ViewBuilder
    private func modelBreakdownDetailed(for estimate: CostEstimate) -> some View {
        let allModels: Set<String> = Set(estimate.modelBreakdownToday.keys)
            .union(estimate.modelBreakdownLast7Days.keys)
        if !allModels.isEmpty {
            let rows: [ModelRow] = allModels.map { model in
                ModelRow(
                    name: model,
                    usdToday: estimate.modelBreakdownToday[model] ?? 0,
                    usd7d:   estimate.modelBreakdownLast7Days[model] ?? 0,
                    todayIsUnpriced: estimate.modelBreakdownToday[model] != nil
                        && estimate.unpricedModelsToday.contains(model),
                    weekIsUnpriced: estimate.modelBreakdownLast7Days[model] != nil
                        && estimate.unpricedModelsLast7Days.contains(model)
                )
            }
            .sorted { ($0.usd7d, $0.usdToday) > ($1.usd7d, $1.usdToday) }

            VStack(alignment: .leading, spacing: 2) {
                // Label on the left, column headers ("hoje / últimos 7 dias")
                // pinned to the right so they sit directly above the
                // corresponding `$X (Y%) / $Z (W%)` value pairs below.
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    L10n.text("models_label")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // Inline spinner while a recompute is in flight, so the
                    // user sees "we're refreshing" even though the previous
                    // values stay visible underneath.
                    if cost.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                    }
                    Spacer(minLength: 6)
                    L10n.text("models_columns_header")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                ForEach(rows) { row in
                    modelRow(row,
                             totalToday: estimate.usdToday,
                             total7d: estimate.usdLast7Days)
                }
            }
            .padding(.leading, 2)
        }
    }

    /// Usage this vendor received through opencode, kept visually separate
    /// from the vendor's own CLI totals above.
    ///
    /// Whether a row shows dollars or tokens is decided by the DATA, not by
    /// hardcoding which vendor is which: opencode records a per-turn cost only
    /// for pay-per-token traffic and leaves it at zero for anything covered by
    /// a subscription. So a zero-cost model is one whose tokens were already
    /// paid for by a plan, and printing a dollar figure for it would invent
    /// spending that never happened.
    ///
    /// The dollars shown here are opencode's own arithmetic, not a re-pricing
    /// from `PricingTable` — it applied the vendor's rates at the time of the
    /// turn, which a hand-maintained table cannot promise to match. They are a
    /// breakdown of a total the vendor card already reports from its API, not
    /// an addition to it.
    @ViewBuilder
    private func opencodeSection(_ scan: OpencodeScan) -> some View {
        let models = Set(scan.last7DaysByModel.keys).union(scan.todayByModel.keys)
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    L10n.text("opencode_label")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                }
                ForEach(models.sorted(), id: \.self) { model in
                    let usd7d = scan.costLast7DaysByModel[model] ?? 0
                    HStack(spacing: 0) {
                        Text("•  ")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                        Text(Self.shortModelName(model))
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        if usd7d > 0 {
                            Text(String(format: "$%.2f", usd7d))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if let usage = scan.last7DaysByModel[model] {
                            Text(Self.compactTokens(usage))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.leading, 2)
        }
    }

    /// "169M in · 2.7B cache · 12M out" — the three buckets that differ by
    /// orders of magnitude, so a single total would hide the cache reads that
    /// dominate. Cache is shown because it is usually the largest number and
    /// its absence would make the row look wrong next to the plan's own meter.
    static func compactTokens(_ u: ModelUsage) -> String {
        // Thresholds sit where the ROUNDED value would reach the next unit, not
        // at the unit itself. Splitting on 1_000_000 renders 999_999 as
        // "1000k" — arithmetically fine, and it reads as a bug.
        func short(_ n: Int) -> String {
            switch n {
            case 999_500_000...: return String(format: "%.1fB", Double(n) / 1e9)
            case 999_500...:     return String(format: "%.0fM", Double(n) / 1e6)
            case 1_000...:       return String(format: "%.0fk", Double(n) / 1e3)
            default:             return "\(n)"
            }
        }
        var parts = ["\(short(u.inputTokens)) in"]
        if u.cacheReadTokens > 0 { parts.append("\(short(u.cacheReadTokens)) cache") }
        parts.append("\(short(u.outputTokens)) out")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func modelRow(_ row: ModelRow, totalToday: Double, total7d: Double) -> some View {
        let todayPct = totalToday > 0 ? Int((row.usdToday / totalToday * 100).rounded()) : 0
        let weekPct  = total7d > 0    ? Int((row.usd7d   / total7d   * 100).rounded()) : 0
        HStack(spacing: 0) {
            Text("•  ")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Text(Self.shortModelName(row.name))
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                // The model id comes from a transcript we don't control, so
                // its length and content are untrusted: a 500-character id or
                // one containing a newline would otherwise stretch or wrap the
                // popover around it.
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if row.todayIsUnpriced {
                L10n.text("price_unavailable_short")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            } else if row.usdToday > 0 {
                Text(String(format: "$%.2f", row.usdToday))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(String(format: " (%d%%)", todayPct))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text("—")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(" / ")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)
            if row.weekIsUnpriced {
                L10n.text("price_unavailable_short")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            } else if row.usd7d > 0 {
                Text(String(format: "$%.2f", row.usd7d))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(String(format: " (%d%%)", weekPct))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text("—")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private struct ModelRow: Identifiable {
        let name: String
        let usdToday: Double
        let usd7d: Double
        let todayIsUnpriced: Bool
        let weekIsUnpriced: Bool
        var id: String { name }
    }

    enum CostAvailability: Equatable {
        case complete
        case partial
        case unavailable
    }

    /// A zero-dollar breakdown can mean either a tiny known cost or no known
    /// price at all. Preserve that distinction all the way into the UI.
    static func costAvailability(
        breakdown: [String: Double],
        unpricedModels: Set<String>
    ) -> CostAvailability {
        guard !breakdown.isEmpty, !unpricedModels.isEmpty else { return .complete }
        let pricedModels = Set(breakdown.keys).subtracting(unpricedModels)
        return pricedModels.isEmpty ? .unavailable : .partial
    }

    private static func costText(
        amount: Double,
        availability: CostAvailability,
        completeKey: String,
        partialKey: String,
        unavailableKey: String
    ) -> String {
        switch availability {
        case .complete:
            return L10n.localizedString(completeKey, amount)
        case .partial:
            return L10n.localizedString(partialKey, amount)
        case .unavailable:
            return L10n.localizedString(unavailableKey)
        }
    }

    /// Strips noisy model-name prefixes for the inline display
    /// ("claude-opus-4-7" → "opus-4-7", "gpt-5-codex" stays as-is).
    private static func shortModelName(_ model: String) -> String {
        if model.hasPrefix("claude-") {
            return String(model.dropFirst("claude-".count))
        }
        return model
    }
}
