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
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)

                        Circle()
                            .fill(vendorColor)
                            .frame(width: 9, height: 9)

                        Text(summary.vendor.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if let plan = summary.planLabel, !plan.isEmpty {
                            Text(plan)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 1) {
                            Text(AnalyticsMoneyFormatter.format(summary.totalCostUSD))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            if summary.totalUsagePercent > 0 {
                                Text("\(Int(summary.totalUsagePercent))% quota")
                                    .font(.caption2)
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
                VStack(alignment: .leading, spacing: 8) {
                    // Peak Day highlight
                    if let peak = summary.peakDay {
                        HStack(spacing: 6) {
                            Text(AnalyticsFormatters.peakDayText(peak))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.orange.opacity(0.12))
                        )
                    }

                    // Session Stats & Delta
                    HStack(spacing: 12) {
                        if summary.sessionCount > 0 {
                            Label("\(summary.sessionCount) \(L10n.localizedString("analytics_sessions"))", systemImage: "macwindow")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let delta = summary.deltaPreviousPeriodPercent {
                            HStack(spacing: 2) {
                                Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                Text(String(format: "%+.1f%%", delta))
                            }
                            .font(.caption2.weight(.semibold).monospacedDigit())
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
                        VStack(spacing: 6) {
                            ForEach(summary.costByModel.sorted(by: { $0.value > $1.value }), id: \.key) { model, cost in
                                let proportion = summary.totalCostUSD > 0 ? (cost / summary.totalCostUSD) : 0
                                VStack(spacing: 2) {
                                    HStack {
                                        Text(model)
                                            .font(.caption)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(AnalyticsMoneyFormatter.format(cost))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule()
                                                .fill(Color.secondary.opacity(0.12))
                                                .frame(height: 4)
                                            Capsule()
                                                .fill(vendorColor.opacity(0.8))
                                                .frame(width: max(4, geo.size.width * CGFloat(proportion)), height: 4)
                                        }
                                    }
                                    .frame(height: 4)
                                }
                            }
                        }
                        .padding(.top, 2)
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
