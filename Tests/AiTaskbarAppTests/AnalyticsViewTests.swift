import Testing
import Foundation
import SwiftUI
@testable import AiTaskbarApp
import AiTaskbarCore

@MainActor
@Suite("AnalyticsView & VendorAnalyticsCardView")
struct AnalyticsViewTests {
    @Test("AnalyticsMoneyFormatter formats standard currency values")
    func money_formatter() {
        #expect(AnalyticsMoneyFormatter.format(0) == "$0.00")
        #expect(AnalyticsMoneyFormatter.format(14.5) == "$14.50")
        #expect(AnalyticsMoneyFormatter.format(1345.67) == "$1,345.67")
        #expect(AnalyticsMoneyFormatter.formatCompact(14500) == "$14.5K")
    }

    @Test("PeakDayFormatter formats date and values")
    func peak_day_formatter() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let record = PeakDayRecord(date: date, costUSD: 42.10, utilizationPercent: 84.0, isHistoricalPeak: true)
        let text = AnalyticsFormatters.peakDayText(record)
        #expect(text.contains("🔥"))
        #expect(text.contains("84%"))
    }
}
