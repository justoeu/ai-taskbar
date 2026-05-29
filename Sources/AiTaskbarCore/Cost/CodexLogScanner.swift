import Foundation
import SQLite3

/// Opens `~/.codex/logs_2.sqlite` read-only and tallies token usage from log
/// records whose `feedback_log_body` carries `model=X ... total_usage_tokens=N`.
/// Codex doesn't break input/output cleanly in this format — we treat the
/// total as input-priced (conservative; real cost is usually lower since most
/// of the budget is reads).
public enum CodexLogScanner {
    public static func estimate(now: Date = .init(),
                                dbPath: String? = nil) -> CostEstimate {
        let path: String = {
            if let dbPath { return dbPath }
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appendingPathComponent(".codex/logs_2.sqlite").path
        }()
        guard FileManager.default.fileExists(atPath: path) else {
            return CostEstimate(usdToday: 0, usdLast7Days: 0,
                                isApproximate: true,
                                note: "No ~/.codex/logs_2.sqlite found.")
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            return CostEstimate(usdToday: 0, usdLast7Days: 0,
                                isApproximate: true,
                                note: "Failed to open Codex sqlite.")
        }
        defer { sqlite3_close(db) }

        let sevenDaysAgo = Int(now.timeIntervalSince1970) - 7 * 86_400
        let startOfToday = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)

        let sql = """
            SELECT ts, feedback_log_body
            FROM logs
            WHERE feedback_log_body LIKE '%total_usage_tokens=%'
              AND ts >= ?
            ORDER BY ts DESC
            LIMIT 5000
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return CostEstimate(usdToday: 0, usdLast7Days: 0,
                                isApproximate: true,
                                note: "sqlite prepare failed.")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(sevenDaysAgo))

        var totalsToday: [String: ModelUsage] = [:]
        var totalsLast7: [String: ModelUsage] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = Int(sqlite3_column_int64(stmt, 0))
            guard let cstr = sqlite3_column_text(stmt, 1) else { continue }
            let body = String(cString: cstr)
            guard let (model, tokens) = parse(body: body) else { continue }
            let usage = ModelUsage(inputTokens: tokens)
            add(usage, into: &totalsLast7, model: model)
            if ts >= startOfToday {
                add(usage, into: &totalsToday, model: model)
            }
        }

        let (usdToday, breakdownToday) = price(totals: totalsToday, table: PricingTable.openai)
        let (usdWeek, breakdownLast7) = price(totals: totalsLast7, table: PricingTable.openai)
        return CostEstimate(
            usdToday: usdToday,
            usdLast7Days: usdWeek,
            modelBreakdownToday: breakdownToday,
            modelBreakdownLast7Days: breakdownLast7,
            totalsByModel: totalsToday,
            computedAt: now,
            isApproximate: true,
            note: totalsToday.isEmpty
                ? "No Codex activity today (or token-usage log fields not populated)."
                : "Approximate — treats total_usage_tokens as input-priced."
        )
    }

    // Anchored at start-of-line or whitespace (covers space + tab + newline)
    // so changes in Codex's log spacing don't silently break extraction.
    // `\S+` for model — matches any non-whitespace identifier.
    // `\d+` for tokens — strictly digits, so a stray malformed value reads as nil.
    private static let modelRegex = try! NSRegularExpression(
        pattern: #"(?:^|\s)model=(\S+)"#)
    private static let tokensRegex = try! NSRegularExpression(
        pattern: #"(?:^|\s)total_usage_tokens=(\d+)"#)

    public static func parse(body: String) -> (model: String, tokens: Int)? {
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let modelMatch = modelRegex.firstMatch(in: body, range: range),
              let modelRange = Range(modelMatch.range(at: 1), in: body),
              let tokensMatch = tokensRegex.firstMatch(in: body, range: range),
              let tokensValueRange = Range(tokensMatch.range(at: 1), in: body),
              let tokens = Int(body[tokensValueRange])
        else { return nil }
        return (String(body[modelRange]), tokens)
    }

    private static func add(_ u: ModelUsage,
                            into bucket: inout [String: ModelUsage],
                            model: String) {
        var existing = bucket[model] ?? ModelUsage()
        existing.inputTokens += u.inputTokens
        existing.outputTokens += u.outputTokens
        existing.cacheReadTokens += u.cacheReadTokens
        existing.cacheCreateTokens += u.cacheCreateTokens
        bucket[model] = existing
    }

    private static func price(totals: [String: ModelUsage],
                              table: [String: ModelPricing]) -> (Double, [String: Double]) {
        var total = 0.0
        var byModel: [String: Double] = [:]
        for (model, usage) in totals {
            guard let pricing = PricingTable.lookup(model, table: table) else { continue }
            let usd = CostMath.cost(usage: usage, pricing: pricing)
            total += usd
            byModel[model] = usd
        }
        return (total, byModel)
    }
}
