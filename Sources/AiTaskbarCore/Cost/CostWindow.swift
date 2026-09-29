import Foundation

/// The single definition of the cost cards' two windows, shared by every
/// local scanner (Claude transcripts, Codex rollouts and logs, opencode).
///
/// "Last 7 days" is **today plus the six previous local calendar days**:
/// it starts at local midnight six days before today. Two things fixed that
/// choice:
///
/// - The scanners are summed into one figure (`AnalyticsStore`), so their
///   windows must agree. They did not: Claude and Codex used
///   `startOfToday - 7 * 86_400` (today plus seven full prior days, i.e. up
///   to eight calendar days) while opencode used a rolling `now - 7 * 86_400`.
/// - The transcript memos (`ScanMemo`) are invalidated per day and store
///   per-record `inWeek` flags. A calendar-day boundary is constant for the
///   whole day, so a replayed flag stays correct; a rolling cutoff would
///   drift under the memo within a day.
///
/// Built with `Calendar.date(byAdding:)` rather than `86_400`-second steps so a
/// DST transition inside the window does not shift the boundary by an hour.
public struct CostWindow: Sendable, Equatable {
    /// Local midnight at the start of `now`'s day.
    public let startOfToday: Date
    /// Local midnight six days before `startOfToday`.
    public let startOfLast7Days: Date

    public init(now: Date, calendar: Calendar = .current) {
        let startOfToday = calendar.startOfDay(for: now)
        self.startOfToday = startOfToday
        self.startOfLast7Days = calendar.date(byAdding: .day, value: -6, to: startOfToday)
            ?? startOfToday.addingTimeInterval(-6 * 86_400)
    }
}
