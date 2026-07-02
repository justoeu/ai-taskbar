import SwiftUI
import AiTaskbarCore

public struct ProviderRowView: View {
    public let window: UsageWindow
    public let thresholds: ThresholdsConfig

    public init(window: UsageWindow, thresholds: ThresholdsConfig = .init()) {
        self.window = window
        self.thresholds = thresholds
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
                    // the date passes. Poll at 1 Hz (popover-only view) so the
                    // moment the reset lands we swap the countdown for an
                    // "awaiting auto-refresh" hint until the next snapshot.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if window.isAwaitingReset(now: context.date) {
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
                if let detail = window.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
