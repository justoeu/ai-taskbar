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
        #expect(AnalyticsMoneyFormatter.format(0.0025) == "< $0.01")
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

    @Test("VendorAnalyticsCardView initializes with reorder affordances")
    func card_view_initialization() {
        let summary = VendorAnalyticsSummary(
            vendor: .anthropic,
            totalCostUSD: 10.0,
            totalUsagePercent: 25.0
        )
        var movedUp = false
        var movedDown = false
        let card = VendorAnalyticsCardView(
            summary: summary,
            canMoveUp: true,
            canMoveDown: false,
            onMoveUp: { movedUp = true },
            onMoveDown: { movedDown = true }
        )
        #expect(card.canMoveUp)
        card.onMoveUp?()
        #expect(movedUp)
        card.onMoveDown?()
        #expect(movedDown)
    }

    @Test("AnalyticsTimeframePicker supports comparisonOffset binding")
    func timeframe_picker_initialization() {
        var timeframe: AnalyticsTimeframe = .weekly
        var compare = true
        var offset = 2
        let timeframeBinding = Binding(get: { timeframe }, set: { timeframe = $0 })
        let compareBinding = Binding(get: { compare }, set: { compare = $0 })
        let offsetBinding = Binding(get: { offset }, set: { offset = $0 })

        _ = AnalyticsTimeframePicker(
            timeframe: timeframeBinding,
            compareWithPrevious: compareBinding,
            comparisonOffset: offsetBinding
        )
        #expect(offset == 2)
    }

    @Test("CenterTrackingNSView scrolls enclosing NSScrollView")
    func center_tracking_scroll() async throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        let docView = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        scrollView.documentView = docView

        let targetView = CenterTrackingNSView(frame: NSRect(x: 0, y: 1000, width: 400, height: 100))
        docView.addSubview(targetView)

        #expect(targetView.enclosingScrollView === scrollView)
        targetView.triggerCenterScroll()

        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(scrollView.contentView.bounds.origin.y > 500)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
