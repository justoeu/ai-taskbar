import Foundation
import SwiftUI
import AiTaskbarCore

public struct AnalyticsView: View {
    @EnvironmentObject private var analyticsStore: AnalyticsStore
    @EnvironmentObject private var usageStore: UsageStore
    @FocusState private var closeButtonFocused: Bool
    public let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    private var enabledVendorIds: [VendorId] {
        usageStore.sortedVendors.map(\.vendorId)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    timeframeSection
                    usageDonutSection
                    costDonutSection
                    vendorCardsSection
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 420, height: 560)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(radius: 20)
        )
        .focusSection()
        .onAppear {
            closeButtonFocused = true
            analyticsStore.refresh()
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                onClose()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)
            .focused($closeButtonFocused)
            .accessibilityLabel(L10n.localizedString("back"))

            VStack(alignment: .leading, spacing: 2) {
                L10n.text("analytics_title")
                    .font(.headline)
                L10n.text("analytics_subtitle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                analyticsStore.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.localizedString("refresh"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var timeframeSection: some View {
        AnalyticsTimeframePicker(
            timeframe: $analyticsStore.timeframe,
            compareWithPrevious: $analyticsStore.compareWithPrevious,
            comparisonOffset: $analyticsStore.comparisonOffset
        )
    }

    private var enabledShares: [VendorShare] {
        let shares = analyticsStore.snapshot?.vendorShares ?? []
        return shares.filter { enabledVendorIds.contains($0.vendor) }
    }

    /// Section 1: Usage Share (% Quota)
    private var usageDonutSection: some View {
        let shares = enabledShares
        let snapshot = analyticsStore.snapshot

        let usageSlices = shares.map { share in
            let usagePct = snapshot?.vendorSummaries.first(where: { $0.vendor == share.vendor })?.totalUsagePercent ?? share.percentage
            return DonutSlice(
                id: share.vendor.rawValue,
                value: max(1.0, usagePct),
                color: AnalyticsFormatters.vendorColor(for: share.vendor),
                label: share.vendor.displayName
            )
        }

        let avgUsage = shares.isEmpty ? 0 : Int(shares.map { share in
            snapshot?.vendorSummaries.first(where: { $0.vendor == share.vendor })?.totalUsagePercent ?? 0
        }.reduce(0, +) / Double(shares.count))

        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.localizedString("analytics_usage_distribution_title"))
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .center, spacing: 16) {
                DonutChartView(slices: usageSlices, lineWidth: 14) {
                    VStack(spacing: 0) {
                        Text(L10n.localizedString("analytics_usage"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(avgUsage)%")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                    }
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 6) {
                    if shares.isEmpty {
                        Text(L10n.localizedString("analytics_empty_data"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(shares) { share in
                            let usagePct = snapshot?.vendorSummaries.first(where: { $0.vendor == share.vendor })?.totalUsagePercent ?? share.percentage
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(AnalyticsFormatters.vendorColor(for: share.vendor))
                                    .frame(width: 8, height: 8)
                                Text(share.vendor.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text(String(format: "%.0f%%", usagePct))
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            )
        }
    }

    /// Section 2: Dollar Cost Consumption (USD)
    private var costDonutSection: some View {
        let shares = enabledShares
        let totalCost = shares.map(\.costUSD).reduce(0, +)

        let costSlices = shares.map { share in
            DonutSlice(
                id: share.vendor.rawValue,
                value: share.costUSD,
                color: AnalyticsFormatters.vendorColor(for: share.vendor),
                label: share.vendor.displayName
            )
        }

        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.localizedString("analytics_cost_distribution_title"))
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .center, spacing: 16) {
                DonutChartView(slices: costSlices, lineWidth: 14) {
                    VStack(spacing: 0) {
                        Text(AnalyticsMoneyFormatter.formatCompact(totalCost))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                        Text("USD")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 6) {
                    if shares.isEmpty {
                        Text(L10n.localizedString("analytics_empty_data"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(shares) { share in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(AnalyticsFormatters.vendorColor(for: share.vendor))
                                    .frame(width: 8, height: 8)
                                Text(share.vendor.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text(AnalyticsMoneyFormatter.format(share.costUSD))
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            )
        }
    }

    private var vendorCardsSection: some View {
        let summaries = (analyticsStore.snapshot?.vendorSummaries ?? [])
            .filter { enabledVendorIds.contains($0.vendor) }
            .sorted { a, b in
                let idxA = usageStore.displayIndex(of: a.vendor) ?? 0
                let idxB = usageStore.displayIndex(of: b.vendor) ?? 0
                return idxA < idxB
            }

        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.localizedString("analytics_by_llm_title"))
                .font(.subheadline.weight(.semibold))

            if summaries.isEmpty {
                Text(L10n.localizedString("analytics_empty_data"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(summaries) { summary in
                    let idx = usageStore.displayIndex(of: summary.vendor)
                    let count = usageStore.displayCount
                    let canUp = (idx ?? 0) > 0
                    let canDown = idx.map { $0 < count - 1 } ?? false

                    VendorAnalyticsCardView(
                        summary: summary,
                        canMoveUp: canUp,
                        canMoveDown: canDown,
                        onMoveUp: { usageStore.moveVendorUp(summary.vendor) },
                        onMoveDown: { usageStore.moveVendorDown(summary.vendor) }
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: summaries.map(\.id))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                onClose()
            } label: {
                Label(L10n.localizedString("back"), systemImage: "chevron.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
