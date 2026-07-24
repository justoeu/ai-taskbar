import Foundation

/// Composition point for the two Codex cost sources.
///
/// `CodexSessionScanner` (rollout transcripts) is authoritative: current Codex
/// builds write per-turn token accounting there. `CodexLogScanner` (the
/// `logs_2.sqlite` `total_usage_tokens=` grep) is kept as a fallback for older
/// installs whose Codex still emits that field.
///
/// The two are deliberately **not** summed. When both have data for the same
/// window they describe the same turns, so adding them would double-count;
/// the sqlite path only runs when the session scan found nothing priceable.
/// Losing a stale legacy row is a smaller error than doubling a real bill.
public enum CodexCost {
    public static func estimate(now: Date = .init(),
                                sessionsDir: URL? = nil,
                                dbPath: String? = nil) -> CostEstimate {
        let (fromSessions, sawUsage) = CodexSessionScanner.estimateDetailed(
            now: now, sessionsDir: sessionsDir)
        // Key the choice on whether the rollout scan found USAGE, not on
        // whether it found DOLLARS. Those differ exactly when a model is
        // missing from `PricingTable` — and that is the likely case, not a
        // remote one: this file's own history is OpenAI shipping ids
        // (`gpt-5.6-sol`, `codex-auto-review`) that only price because someone
        // added them by hand. Keying on dollars would hand the display to the
        // dead sqlite scanner the day a new id lands, showing stale numbers
        // with no signal that the live source was the one with real data.
        if sawUsage {
            return fromSessions
        }
        let fromLogs = CodexLogScanner.estimate(now: now, dbPath: dbPath)
        if fromLogs.usdToday > 0 || fromLogs.usdLast7Days > 0 {
            return fromLogs
        }
        // Neither source has anything. Prefer the session scanner's note — it
        // reflects the path that matters on current Codex builds, so "No
        // recent Codex sessions found." is the actionable message rather than
        // a complaint about a sqlite file that no longer carries usage.
        return fromSessions
    }
}
