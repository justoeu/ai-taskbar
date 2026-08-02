import SwiftUI
import AiTaskbarCore

public struct ProviderRowView: View {
    public let window: UsageWindow
    public let thresholds: ThresholdsConfig
    /// Shared 1 Hz clock from the parent (N1-NEX-005). When nil, falls back
    /// to a local TimelineView for previews/tests.
    public var now: Date?

    public init(window: UsageWindow,
                thresholds: ThresholdsConfig = .init(),
                now: Date? = nil) {
        self.window = window
        self.thresholds = thresholds
        self.now = now
    }

    public var body: some View {
        let percent = window.utilizationPercent
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(SeverityColor.tint(forPercent: percent, thresholds: thresholds))
            }
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(SeverityColor.tint(forPercent: percent, thresholds: thresholds))
            HStack(spacing: 8) {
                if let resetsAt = window.resetsAt {
                    // SwiftUI's `.relative` date style keeps counting UP once
                    // the date passes. Prefer a parent-supplied 1 Hz clock so
                    // N windows do not each mount TimelineView.periodic.
                    if let now {
                        resetLabel(resetsAt: resetsAt, now: now)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            resetLabel(resetsAt: resetsAt, now: context.date)
                        }
                    }
                }
                if let detail = window.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func resetLabel(resetsAt: Date, now: Date) -> some View {
        if window.isAwaitingReset(now: now) {
            L10n.text("reset_waiting_refresh")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            (Text(L10n.localizedString("resets_prefix"))
                + Text(" ")
                + Text(resetsAt, style: .relative))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
