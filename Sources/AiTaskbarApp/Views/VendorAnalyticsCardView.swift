import Foundation
import SwiftUI
import AiTaskbarCore

public struct VendorAnalyticsCardView: View {
    public let summary: VendorAnalyticsSummary
    public let canMoveUp: Bool
    public let canMoveDown: Bool
    public let onMoveUp: (() -> Void)?
    public let onMoveDown: (() -> Void)?

    @State private var isExpanded: Bool = true

    public init(
        summary: VendorAnalyticsSummary,
        canMoveUp: Bool = false,
        canMoveDown: Bool = false,
        onMoveUp: (() -> Void)? = nil,
        onMoveDown: (() -> Void)? = nil
    ) {
        self.summary = summary
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
    }

    private var vendorColor: Color {
        AnalyticsFormatters.vendorColor(for: summary.vendor)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Row: Accordion toggle + Reorder controls
            HStack(alignment: .center, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)

                        VendorIconView(vendorId: summary.vendor, size: 16)
                            .foregroundStyle(vendorColor)
                            .frame(width: 16, height: 16)

                        Text(summary.vendor.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if let plan = summary.planLabel, !plan.isEmpty {
                            Text(plan)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(AnalyticsMoneyFormatter.format(summary.totalCostUSD))
                                .font(.headline.monospacedDigit())
                            if summary.totalUsagePercent > 0 {
                                Text("\(Int(summary.totalUsagePercent))% quota")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Reorder controls
                HStack(spacing: 0) {
                    Button {
                        onMoveUp?()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.bold))
                            .frame(width: 18, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveUp)
                    .help(L10n.localizedString("move_vendor_up_help"))

                    Button {
                        onMoveDown?()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .frame(width: 18, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canMoveDown)
                    .help(L10n.localizedString("move_vendor_down_help"))
                }
                .foregroundStyle(.secondary)
            }

            // Accordion Content
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    // Peak Day highlight
                    if let peak = summary.peakDay {
                        HStack(spacing: 6) {
                            Text(AnalyticsFormatters.peakDayText(peak))
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.orange.opacity(0.12))
                        )
                    }

                    // Lifetime usage (e.g. OpenRouter accumulated account usage)
                    if let lifetime = summary.lifetimeCostUSD, lifetime > 0 {
                        HStack {
                            Text(L10n.localizedString("analytics_lifetime_usage"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(AnalyticsMoneyFormatter.format(lifetime))
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.secondary.opacity(0.08))
                        )
                    }

                    // Session Stats & Delta
                    HStack(spacing: 12) {
                        if summary.sessionCount > 0 {
                            let sessionLabel = summary.sessionCount == 1
                                ? "1 \(L10n.localizedString("analytics_session_single"))"
                                : "\(summary.sessionCount) \(L10n.localizedString("analytics_sessions"))"
                            Label(sessionLabel, systemImage: "macwindow")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if let delta = summary.deltaPreviousPeriodPercent {
                            HStack(spacing: 2) {
                                Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                Text(String(format: "%+.1f%%", delta))
                            }
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(delta >= 0 ? Color.red : Color.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill((delta >= 0 ? Color.red : Color.green).opacity(0.12))
                            )
                        }
                    }

                    // Model Breakdown
                    if !summary.costByModel.isEmpty {
                        VStack(spacing: 7) {
                            ForEach(summary.costByModel.sorted(by: { $0.value > $1.value }), id: \.key) { model, cost in
                                let proportion = summary.totalCostUSD > 0 ? (cost / summary.totalCostUSD) : 0
                                VStack(spacing: 3) {
                                    HStack {
                                        Text(model)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(AnalyticsMoneyFormatter.format(cost))
                                            .font(.callout.monospacedDigit().weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule()
                                                .fill(Color.secondary.opacity(0.12))
                                                .frame(height: 5)
                                            Capsule()
                                                .fill(vendorColor.opacity(0.85))
                                                .frame(width: max(5, geo.size.width * CGFloat(proportion)), height: 5)
                                        }
                                    }
                                    .frame(height: 5)
                                }
                            }
                        }
                        .padding(.top, 4)
                    } else if summary.totalCostUSD <= 0.0001 && summary.totalUsagePercent > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.callout)
                                .foregroundStyle(Color.accentColor)
                            Text(L10n.localizedString("analytics_subscription_quota_hint"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                    }

                    // Empty state when there is no usage data
                    let hasNoData = summary.costByModel.isEmpty
                        && summary.sessionCount == 0
                        && summary.peakDay == nil
                        && (summary.lifetimeCostUSD == nil || summary.lifetimeCostUSD == 0)
                        && summary.totalCostUSD <= 0.0001
                        && summary.totalUsagePercent <= 0.0001

                    if hasNoData {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(L10n.localizedString("analytics_vendor_no_recent_usage"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}
