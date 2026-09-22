import Foundation
import SwiftUI
import AiTaskbarCore

public struct AnalyticsView: View {
    @EnvironmentObject private var analyticsStore: AnalyticsStore
    @FocusState private var closeButtonFocused: Bool
    public let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    timeframeSection
                    dualDonutSection
                    vendorCardsSection
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 420, height: 540)
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
            .accessibilityLabel(L10n.localizedString("done"))

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
            compareWithPrevious: $analyticsStore.compareWithPrevious
        )
    }

    private var dualDonutSection: some View {
        let snapshot = analyticsStore.snapshot
        let shares = snapshot?.vendorShares ?? []
        let totalCost = snapshot?.totalCostUSD ?? 0

        let usageSlices = shares.map { share in
            DonutSlice(
                id: share.vendor.rawValue,
                value: share.percentage,
                color: AnalyticsFormatters.vendorColor(for: share.vendor),
                label: share.vendor.displayName
            )
        }

        let costSlices = shares.map { share in
            DonutSlice(
                id: share.vendor.rawValue,
                value: share.costUSD,
                color: AnalyticsFormatters.vendorColor(for: share.vendor),
                label: share.vendor.displayName
            )
        }

        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.localizedString("analytics_distribution_title"))
                .font(.subheadline.weight(.semibold))

            HStack(alignment: .center, spacing: 14) {
                // Left donut: Usage %
                VStack(spacing: 4) {
                    DonutChartView(slices: usageSlices, lineWidth: 12) {
                        VStack(spacing: 0) {
                            Text(L10n.localizedString("analytics_usage"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            let avgPct = shares.isEmpty ? 0 : Int(shares.map(\.percentage).reduce(0, +) / Double(shares.count))
                            Text("\(avgPct)%")
                                .font(.caption.weight(.semibold).monospacedDigit())
                        }
                    }
                    .frame(width: 80, height: 80)

                    Text(L10n.localizedString("analytics_usage_share"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Right donut: Cost ($) with Legend
                HStack(alignment: .center, spacing: 10) {
                    DonutChartView(slices: costSlices, lineWidth: 14) {
                        VStack(spacing: 0) {
                            Text(AnalyticsMoneyFormatter.formatCompact(totalCost))
                                .font(.caption.weight(.bold).monospacedDigit())
                            Text("USD")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 90, height: 90)

                    // Vertical legend matching screenshot
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(shares.prefix(5)) { share in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(AnalyticsFormatters.vendorColor(for: share.vendor))
                                    .frame(width: 7, height: 7)
                                Text(share.vendor.displayName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer()
                                Text(AnalyticsMoneyFormatter.format(share.costUSD))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            )
        }
    }

    private var vendorCardsSection: some View {
        let summaries = analyticsStore.snapshot?.vendorSummaries ?? []
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
                    VendorAnalyticsCardView(summary: summary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.localizedString("done")) {
                onClose()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
