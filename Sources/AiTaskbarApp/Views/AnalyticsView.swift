import Foundation
import SwiftUI
import AiTaskbarCore

public struct AnalyticsView: View {
    @EnvironmentObject private var analyticsStore: AnalyticsStore
    @EnvironmentObject private var usageStore: UsageStore
    @FocusState private var closeButtonFocused: Bool
    public let onClose: () -> Void

    @State private var hoveredUsageVendor: String? = nil
    @State private var hoveredCostVendor: String? = nil

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    private var enabledVendorIds: [VendorId] {
        usageStore.sortedVendors.filter { !$0.isDisabled }.map(\.vendorId)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            syncOrderBar
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
        .onChange(of: analyticsStore.syncVendorOrder) { synced in
            if synced {
                analyticsStore.analyticsOrder = usageStore.sortedVendors.map(\.vendorId)
            }
        }
        .onExitCommand(perform: close)
    }

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

    private var syncOrderBar: some View {
        VendorOrderSyncBar(isOn: $analyticsStore.syncVendorOrder)
    }

    /// Also the popover toolbar button's icon.
    static let headerSymbol = "chart.pie.fill"

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // The feature's own icon (same as the popover button that opens
            // it), like the Service Status page; "Back" lives in the footer.
            Image(systemName: Self.headerSymbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                L10n.text("analytics_title")
                    .font(.title3.weight(.bold))
                HStack(spacing: 4) {
                    L10n.text("analytics_subtitle")
                        .foregroundStyle(.secondary)
                    if analyticsStore.isRefreshing {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(L10n.localizedString("refreshing_now"))
                            .foregroundStyle(Color.accentColor)
                    } else if let refreshed = analyticsStore.lastRefreshedAt {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(L10n.localizedString("service_status_updated_fmt", Self.timeFormatter.string(from: refreshed)))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }

            Spacer()

            Button {
                analyticsStore.refresh(force: true)
            } label: {
                if analyticsStore.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                }
            }
            .buttonStyle(.plain)
            .disabled(analyticsStore.isRefreshing)
            .help(L10n.localizedString("refresh"))
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

        let avgUsage = AnalyticsFormatters.averageUsageText(
            vendors: shares.map(\.vendor), summaries: snapshot?.vendorSummaries ?? [])

        let hoveredSlice = usageSlices.first(where: { $0.id == hoveredUsageVendor })

        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.localizedString("analytics_usage_distribution_title"))
                .font(.headline)

            HStack(alignment: .center, spacing: 16) {
                DonutChartView(slices: usageSlices, lineWidth: 14, hoveredId: $hoveredUsageVendor) {
                    VStack(spacing: 0) {
                        if let h = hoveredSlice {
                            Text(h.label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(PercentText.format(h.value))
                                .font(.headline.weight(.bold).monospacedDigit())
                                .foregroundStyle(h.color)
                        } else {
                            Text(L10n.localizedString("analytics_usage"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(avgUsage)
                                .font(.headline.weight(.bold).monospacedDigit())
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: hoveredUsageVendor)
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 4) {
                    if shares.isEmpty {
                        Text(L10n.localizedString("analytics_empty_data"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(shares) { share in
                            let usagePct = snapshot?.vendorSummaries.first(where: { $0.vendor == share.vendor })?.totalUsagePercent ?? share.percentage
                            let isHovered = hoveredUsageVendor == share.vendor.rawValue
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(AnalyticsFormatters.vendorColor(for: share.vendor))
                                    .frame(width: 9, height: 9)
                                Text(share.vendor.displayName)
                                    .font(.callout.weight(isHovered ? .bold : .medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(PercentText.format(usagePct))
                                    .font(.callout.monospacedDigit().weight(isHovered ? .bold : .medium))
                                    .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                            )
                            .opacity(hoveredUsageVendor == nil || isHovered ? 1.0 : 0.45)
                            .contentShape(Rectangle())
                            .onHover { h in
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                    hoveredUsageVendor = h ? share.vendor.rawValue : nil
                                }
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
        let shares = enabledShares.filter { $0.costUSD > 0 }
        let totalCost = shares.map(\.costUSD).reduce(0, +)

        let costSlices = shares.map { share in
            DonutSlice(
                id: share.vendor.rawValue,
                value: share.costUSD,
                color: AnalyticsFormatters.vendorColor(for: share.vendor),
                label: share.vendor.displayName
            )
        }

        let hoveredSlice = costSlices.first(where: { $0.id == hoveredCostVendor })
        let costAvailable = analyticsStore.snapshot?.isCostAvailable ?? true

        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.localizedString("analytics_cost_distribution_title"))
                .font(.headline)

            HStack(alignment: .center, spacing: 16) {
                DonutChartView(slices: costSlices, lineWidth: 14, hoveredId: $hoveredCostVendor) {
                    VStack(spacing: 0) {
                        if let h = hoveredSlice {
                            Text(h.label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(AnalyticsMoneyFormatter.format(h.value))
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(h.color)
                        } else {
                            Text(costAvailable ? AnalyticsMoneyFormatter.formatCompact(totalCost) : "—")
                                .font(.headline.weight(.bold).monospacedDigit())
                            Text("USD")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: hoveredCostVendor)
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 4) {
                    if !costAvailable {
                        // Month: the scanners keep 7 days, so there is no
                        // 30-day cost to show — say so instead of "$0".
                        Text(L10n.localizedString("analytics_cost_7d_only"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if shares.isEmpty {
                        Text(L10n.localizedString("analytics_empty_data"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(shares) { share in
                            let isHovered = hoveredCostVendor == share.vendor.rawValue
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(AnalyticsFormatters.vendorColor(for: share.vendor))
                                    .frame(width: 9, height: 9)
                                Text(share.vendor.displayName)
                                    .font(.callout.weight(isHovered ? .bold : .medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(AnalyticsMoneyFormatter.format(share.costUSD))
                                    .font(.callout.monospacedDigit().weight(isHovered ? .bold : .medium))
                                    .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                            )
                            .opacity(hoveredCostVendor == nil || isHovered ? 1.0 : 0.45)
                            .contentShape(Rectangle())
                            .onHover { h in
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                    hoveredCostVendor = h ? share.vendor.rawValue : nil
                                }
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

    private var sortedSummaries: [VendorAnalyticsSummary] {
        let summaries = (analyticsStore.snapshot?.vendorSummaries ?? [])
            .filter { enabledVendorIds.contains($0.vendor) }

        if analyticsStore.syncVendorOrder {
            return summaries.sorted { a, b in
                let idxA = usageStore.displayIndex(of: a.vendor) ?? 0
                let idxB = usageStore.displayIndex(of: b.vendor) ?? 0
                return idxA < idxB
            }
        } else {
            return summaries.sorted { a, b in
                let idxA = analyticsStore.displayIndex(of: a.vendor)
                let idxB = analyticsStore.displayIndex(of: b.vendor)
                return idxA < idxB
            }
        }
    }

    private var vendorCardsSection: some View {
        let summaries = sortedSummaries

        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.localizedString("analytics_by_llm_title"))
                .font(.title3.weight(.bold))

            if summaries.isEmpty {
                Text(L10n.localizedString("analytics_empty_data"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(summaries) { summary in
                    let count = summaries.count
                    let idx = summaries.firstIndex(where: { $0.vendor == summary.vendor }) ?? 0
                    let canUp = idx > 0
                    let canDown = idx < count - 1
                    let isTargeted = summary.vendor == analyticsStore.targetVendor

                    VendorAnalyticsCardView(
                        summary: summary,
                        timeframe: analyticsStore.timeframe,
                        compareWithPrevious: analyticsStore.compareWithPrevious,
                        comparisonOffset: analyticsStore.comparisonOffset,
                        canMoveUp: canUp,
                        canMoveDown: canDown,
                        onMoveUp: {
                            if analyticsStore.syncVendorOrder {
                                usageStore.moveVendorUp(summary.vendor)
                            } else {
                                analyticsStore.moveVendorUp(summary.vendor, enabled: enabledVendorIds)
                            }
                        },
                        onMoveDown: {
                            if analyticsStore.syncVendorOrder {
                                usageStore.moveVendorDown(summary.vendor)
                            } else {
                                analyticsStore.moveVendorDown(summary.vendor, enabled: enabledVendorIds)
                            }
                        }
                    )
                    .background(
                        ScrollToCenterView(shouldCenter: isTargeted)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                    .shadow(color: isTargeted ? Color.accentColor.opacity(0.35) : Color.clear, radius: 8, x: 0, y: 2)
                    .id(summary.vendor)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: summaries.map(\.id))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                close()
            } label: {
                Label(L10n.localizedString("back"), systemImage: "chevron.backward")
            }
            .focused($closeButtonFocused)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func close() {
        analyticsStore.targetVendor = nil
        onClose()
    }
}
