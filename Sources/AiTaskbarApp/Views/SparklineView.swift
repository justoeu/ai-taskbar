import SwiftUI
import AiTaskbarCore

/// Sparkline with axis hints: dashed threshold lines (warning/critical),
/// current value annotation on the right edge, and 24h time markers below.
public struct SparklineView: View {
    public let samples: [UsageHistoryStore.Sample]
    public let span: TimeInterval
    public let thresholds: ThresholdsConfig

    public init(samples: [UsageHistoryStore.Sample],
                span: TimeInterval = 24 * 3600,
                thresholds: ThresholdsConfig = .init()) {
        self.samples = samples
        self.span = span
        self.thresholds = thresholds
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                let now = Date.now.timeIntervalSince1970
                let start = now - span
                let filtered = samples.filter { $0.at >= start && $0.at <= now }
                if filtered.count < 2 {
                    L10n.text("building_history")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    chartContent(geo: geo, samples: filtered, start: start)
                }
            }
            .frame(height: 36)
            axisLabels
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func chartContent(geo: GeometryProxy,
                              samples: [UsageHistoryStore.Sample],
                              start: TimeInterval) -> some View {
        let w = geo.size.width
        let h = geo.size.height
        let maxPercent = samples.map(\.max).max() ?? 0
        let currentPercent = samples.last?.max ?? 0
        let tint = SeverityColor.tint(forPercent: currentPercent, thresholds: thresholds)

        // Reserve a strip on the right for the current-value annotation so
        // the line + label don't overlap.
        let valueLabelWidth: CGFloat = 32
        let plotWidth = Swift.max(w - valueLabelWidth, 1)

        let xFor: (TimeInterval) -> CGFloat = { at in
            CGFloat((at - start) / self.span) * plotWidth
        }
        let yFor: (Double) -> CGFloat = { percent in
            h - CGFloat(Swift.min(Swift.max(percent, 0), 100) / 100) * h
        }

        ZStack(alignment: .topLeading) {
            // Dashed reference lines at warning + critical thresholds.
            Path { p in
                let yWarn = yFor(thresholds.warning)
                p.move(to: CGPoint(x: 0, y: yWarn))
                p.addLine(to: CGPoint(x: plotWidth, y: yWarn))
            }
            .stroke(Color.yellow.opacity(0.30),
                    style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            Path { p in
                let yCrit = yFor(thresholds.critical)
                p.move(to: CGPoint(x: 0, y: yCrit))
                p.addLine(to: CGPoint(x: plotWidth, y: yCrit))
            }
            .stroke(Color.orange.opacity(0.35),
                    style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            // Filled area under the curve.
            Path { p in
                var firstX: CGFloat = 0
                for (i, s) in samples.enumerated() {
                    let px = xFor(s.at)
                    let py = yFor(s.max)
                    if i == 0 {
                        firstX = px
                        p.move(to: CGPoint(x: px, y: h))
                        p.addLine(to: CGPoint(x: px, y: py))
                    } else {
                        p.addLine(to: CGPoint(x: px, y: py))
                    }
                }
                if let last = samples.last {
                    p.addLine(to: CGPoint(x: xFor(last.at), y: h))
                    p.addLine(to: CGPoint(x: firstX, y: h))
                    p.closeSubpath()
                }
            }
            .fill(tint.opacity(0.20))

            // Stroke line.
            Path { p in
                for (i, s) in samples.enumerated() {
                    let pt = CGPoint(x: xFor(s.at), y: yFor(s.max))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

            // Current-value endpoint dot + label on the right.
            if let last = samples.last {
                Circle()
                    .fill(tint)
                    .frame(width: 4, height: 4)
                    .position(x: xFor(last.at), y: yFor(last.max))
                Text("\(Int(last.max.rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(tint)
                    .position(x: plotWidth + valueLabelWidth / 2,
                              y: yFor(last.max))
            }

            // Peak indicator when meaningfully higher than current — surfaces
            // recent spikes that may have already drained.
            if maxPercent > currentPercent + 5 {
                Text("↑\(Int(maxPercent.rounded()))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .position(x: plotWidth + valueLabelWidth / 2,
                              y: yFor(maxPercent) - 8)
            }
        }
    }

    /// Small "-24h" / "now" labels below the chart for temporal context.
    ///
    /// Explicit `@MainActor` because the computed property doesn't inherit
    /// the body's main-actor isolation under Swift 6, and `L10n.text` is
    /// main-actor-isolated (the `languageOverride` it reads is mutable).
    @MainActor
    private var axisLabels: some View {
        HStack {
            Text("-24h")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            L10n.text("now")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.trailing, 28)   // align under the right edge of the plot
        }
    }
}
