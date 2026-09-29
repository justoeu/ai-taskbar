import Testing
import Foundation
@testable import AiTaskbarApp
@testable import AiTaskbarCore
import AiTaskbarProviders

/// The App formats vendor / history percentages with integer conversions.
/// An absurd value that reached these formatters trapped the whole app —
/// on every launch while it sat in the cache or the 90-day history
/// (B3-numeric: SEC-CER-002/003/004).
@MainActor
@Suite("Numeric conversion traps — App formatters")
struct NumericConversionTrapAppTests {
    @Test("Busiest-day text survives an absurd persisted utilization")
    func peak_day_text_huge_utilization() {
        let record = PeakDayRecord(date: Date(timeIntervalSince1970: 1_700_000_000),
                                   costUSD: 0, utilizationPercent: 1e300)
        let text = AnalyticsFormatters.peakDayText(record)
        #expect(text.contains("\(Int.max)% quota"))
    }

    @Test("Busiest-day text keeps truncating normal values")
    func peak_day_text_normal_utilization() {
        let record = PeakDayRecord(date: Date(timeIntervalSince1970: 1_700_000_000),
                                   costUSD: 1, utilizationPercent: 84.9)
        #expect(AnalyticsFormatters.peakDayText(record).contains("84% quota"))
    }

    @Test("Menu-bar tooltip survives an Anthropic utilization of 1e300 end to end")
    func tooltip_huge_anthropic_utilization() throws {
        let json = #"{ "five_hour": { "utilization": 1e300 } }"#
        let parsed = try JSONDecoder().decode(AnthropicUsageResponse.self, from: Data(json.utf8))
        let snap = VendorSnapshot.anthropic(parsed.toSnapshot(planLabel: nil))
        let text = MenuBarTooltipBuilder.buildTooltip(vendorId: .anthropic, snapshot: nil,
                                                      currentPercent: snap.maxUtilization)
        #expect(text == "Claude: 1000%")
    }

    @Test("Whole-percent formatting saturates non-finite values and rounds normal ones")
    func whole_percent_formatting() {
        #expect(MenuBarTooltipBuilder.buildTooltip(vendorId: .anthropic, snapshot: nil,
                                                   currentPercent: .nan) == "Claude: 0%")
        #expect(MenuBarTooltipBuilder.buildTooltip(vendorId: .anthropic, snapshot: nil,
                                                   currentPercent: 41.6) == "Claude: 42%")
    }
}
