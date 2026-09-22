import Foundation
import SwiftUI
import AiTaskbarCore

public struct AnalyticsTimeframePicker: View {
    @Binding public var timeframe: AnalyticsTimeframe
    @Binding public var compareWithPrevious: Bool

    public init(timeframe: Binding<AnalyticsTimeframe>, compareWithPrevious: Binding<Bool>) {
        self._timeframe = timeframe
        self._compareWithPrevious = compareWithPrevious
    }

    public var body: some View {
        VStack(spacing: 8) {
            Picker("Timeframe", selection: $timeframe) {
                Text(L10n.localizedString("timeframe_daily")).tag(AnalyticsTimeframe.daily)
                Text(L10n.localizedString("timeframe_weekly")).tag(AnalyticsTimeframe.weekly)
                Text(L10n.localizedString("timeframe_monthly")).tag(AnalyticsTimeframe.monthly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle(isOn: $compareWithPrevious) {
                Text(L10n.localizedString("compare_previous_period"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
        }
    }
}
