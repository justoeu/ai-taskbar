import Foundation
import SwiftUI
import AiTaskbarCore

public struct AnalyticsTimeframePicker: View {
    @Binding public var timeframe: AnalyticsTimeframe
    @Binding public var compareWithPrevious: Bool
    @Binding public var comparisonOffset: Int

    public init(
        timeframe: Binding<AnalyticsTimeframe>,
        compareWithPrevious: Binding<Bool>,
        comparisonOffset: Binding<Int>
    ) {
        self._timeframe = timeframe
        self._compareWithPrevious = compareWithPrevious
        self._comparisonOffset = comparisonOffset
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

            HStack(alignment: .center) {
                Toggle(isOn: $compareWithPrevious) {
                    Text(L10n.localizedString("compare_previous_period"))
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .toggleStyle(.checkbox)

                if compareWithPrevious {
                    Spacer()
                    Picker("", selection: $comparisonOffset) {
                        switch timeframe {
                        case .daily:
                            Text(L10n.localizedString("compare_prev_day_1")).tag(1)
                            Text(L10n.localizedString("compare_prev_day_7")).tag(7)
                        case .weekly:
                            Text(L10n.localizedString("compare_prev_week_1")).tag(1)
                            Text(L10n.localizedString("compare_prev_week_2")).tag(2)
                            Text(L10n.localizedString("compare_prev_week_3")).tag(3)
                            Text(L10n.localizedString("compare_prev_week_4")).tag(4)
                        case .monthly:
                            Text(L10n.localizedString("compare_prev_month_1")).tag(1)
                            Text(L10n.localizedString("compare_prev_month_2")).tag(2)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
            }
        }
    }
}
