import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("CostWindow — the shared today / last-7-days definition")
struct CostWindowTests {
    private func calendar(_ zone: String) throws -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: zone))
        return cal
    }

    @Test("last 7 days = today plus the six previous local days")
    func spans_seven_calendar_days() throws {
        let cal = try calendar("America/Sao_Paulo")
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 9, day: 29,
                                                             hour: 23, minute: 59)))
        let window = CostWindow(now: now, calendar: cal)
        let today = cal.dateComponents([.year, .month, .day, .hour, .minute], from: window.startOfToday)
        let start = cal.dateComponents([.year, .month, .day, .hour, .minute], from: window.startOfLast7Days)
        #expect(today == DateComponents(year: 2026, month: 9, day: 29, hour: 0, minute: 0))
        #expect(start == DateComponents(year: 2026, month: 9, day: 23, hour: 0, minute: 0))
    }

    /// A 23-hour day inside the window must not move the boundary off
    /// midnight, which fixed `86_400`-second steps would do.
    @Test("a DST transition inside the window keeps the start at local midnight")
    func dst_keeps_midnight() throws {
        let cal = try calendar("America/New_York")   // DST began 2026-03-08
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let window = CostWindow(now: now, calendar: cal)
        let start = cal.dateComponents([.year, .month, .day, .hour], from: window.startOfLast7Days)
        #expect(start == DateComponents(year: 2026, month: 3, day: 4, hour: 0))
        #expect(window.startOfToday.timeIntervalSince(window.startOfLast7Days) == 6 * 86_400 - 3_600)
    }
}
