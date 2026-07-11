import SwiftUI
import AiTaskbarCore

/// Isolated observer for the shared `CostEstimator`. Lives in its own view so
/// a `cost.refresh()` (every ≥60 s, flipping `isLoading` / `byVendor` /
/// `lastComputedAt`) re-renders **only** the per-vendor cost footer, not the
/// entire `VendorSectionView`. The other 4 sections that don't surface cost
/// data (Z.AI, OpenRouter, Kimi, Gemini, DeepSeek, xAI) never subscribe.
public struct CostFooterView: View {
    private let vendorId: VendorId
    @ObservedObject private var cost: CostEstimator

    public init(vendorId: VendorId, cost: CostEstimator) {
        self.vendorId = vendorId
        self.cost = cost
    }

    public var body: some View {
        let estimate = cost.byVendor[vendorId]
        let hasData = (estimate?.usdToday ?? 0) > 0 || (estimate?.usdLast7Days ?? 0) > 0
        let supportsLocal = CostEstimator.supportedVendors.contains(vendorId)
        // Render the footer when we already have data, OR while we're loading
        // for a vendor that the local scanners cover. Otherwise (OpenRouter,
        // Z.AI, Kimi, DeepSeek without data), stay hidden.
        if hasData, let estimate {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Label(L10n.localizedString("today_cost_fmt", estimate.usdToday),
                          systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label(L10n.localizedString("weekly_cost_fmt", estimate.usdLast7Days),
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
                    usd7d:   estimate.modelBreakdownLast7Days[model] ?? 0
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
            Spacer(minLength: 6)
            if row.usdToday > 0 {
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
            if row.usd7d > 0 {
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
        var id: String { name }
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
