import Foundation
import SQLite3

/// Per-model usage read out of opencode's local database, split into the two
/// windows the cards display.
///
/// `costByModel*` carries the dollar figure **opencode itself computed** for a
/// turn, not something derived here. For a pay-per-token provider that number
/// is the vendor's own arithmetic against the rates in force at the time, which
/// beats re-pricing from a table this repo maintains by hand. It is `0` for
/// subscription traffic, where there is no marginal cost to report.
public struct OpencodeScan: Sendable, Equatable {
    public var todayByModel: [String: ModelUsage] = [:]
    public var last7DaysByModel: [String: ModelUsage] = [:]
    public var costTodayByModel: [String: Double] = [:]
    public var costLast7DaysByModel: [String: Double] = [:]
    /// Rows the scan skipped, and why. Surfaced so a silently empty card can be
    /// told apart from a card that is empty because nothing ran.
    public var skippedRows: Int = 0

    public init() {}

    public var isEmpty: Bool { todayByModel.isEmpty && last7DaysByModel.isEmpty }
}

/// Reads `~/.local/share/opencode/opencode.db` and tallies token usage per
/// model for one provider.
///
/// ## Why per-message and not per-session
///
/// `session` carries convenient aggregate columns (`model`, `tokens_input`,
/// `tokens_cache_read`, …) and reading them is ~30x faster. It is also wrong:
/// `session.model` holds the LAST model the session used, so every token a
/// session spent before a model switch gets attributed to whatever it ended on.
/// Measured on this machine, 4 of 1372 sessions are mixed-model and they carry
/// disproportionate volume — one had `session.model = gpt-5.5` while 1747 of its
/// messages ran `glm-5.2` (8.0M tokens) and 151 ran `z-ai/glm-5.2` (12.3M).
/// Session-level attribution would file ~20M tokens under a model that never
/// spent them. The per-message path costs about a second and is correct.
///
/// ## Three field semantics that are not guessable
///
/// All three were established against the real database, and each one silently
/// corrupts the numbers if assumed the other way:
///
/// 1. **`tokens.input` EXCLUDES `tokens.cache.read`** — the opposite of Codex's
///    rollout format, where input is inclusive. Verified on turns carrying
///    ~200k cache reads whose `input` stayed in the hundreds. Folding cache
///    reads into input here would multiply the input bucket by roughly 16x.
/// 2. **`tokens.reasoning` is DISJOINT from `tokens.output`**, not a subset of
///    it. 6458 of 21910 assistant turns report `reasoning > output`, which is
///    impossible for a subset. Billed output is therefore `output + reasoning`.
/// 3. **The JSON path is `$.tokens.cache.read`**, not `$.tokens.read`. The
///    shorter path silently matches nothing and yields a scan that looks
///    successful and reports zero cache.
public enum OpencodeScanner {
    public static func defaultDatabasePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    /// Scans usage for `providerID` (opencode's own vendor key: `openai`,
    /// `xai`, `anthropic`, …). Returns nil when there is no database to read,
    /// which callers should treat as "opencode isn't installed", not as zero.
    public static func scan(now: Date = .init(),
                            provider: String,
                            dbPath: String? = nil) -> OpencodeScan? {
        scan(now: now, providers: [provider], dbPath: dbPath)
    }

    /// Scans several opencode provider aliases in one database pass. Some
    /// vendors have more than one stable billing identity — Z.AI currently
    /// writes both `zai` and `zai-coding-plan` — and treating the latter as a
    /// different vendor made current GLM models disappear from the Z.AI card.
    public static func scan(now: Date = .init(),
                            providers: [String],
                            dbPath: String? = nil) -> OpencodeScan? {
        scan(now: now,
             providerGroups: ["combined": providers],
             dbPath: dbPath)?["combined"]
    }

    /// Scans every requested vendor group in one SQLite pass. The dictionary
    /// key is caller-owned (the app uses `VendorId.rawValue`); each value lists
    /// the opencode provider aliases billed to that vendor.
    public static func scan(now: Date = .init(),
                            providerGroups: [String: [String]],
                            dbPath: String? = nil) -> [String: OpencodeScan]? {
        guard !Task.isCancelled else { return nil }
        var groupByProvider: [String: String] = [:]
        for group in providerGroups.keys.sorted() {
            for provider in Set(providerGroups[group, default: []]).sorted()
            where !provider.isEmpty {
                // An alias cannot be attributed to two billing vendors.
                guard groupByProvider[provider] == nil else { return nil }
                groupByProvider[provider] = group
            }
        }
        let providerIDs = groupByProvider.keys.sorted()
        guard !providerIDs.isEmpty else { return nil }
        let path = dbPath ?? defaultDatabasePath()
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        // Read-only, and never create: this database belongs to another
        // application that may be running right now. FULLMUTEX because the
        // handle is opened from whichever queue the refresh lands on.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        // Abort `sqlite3_step` itself when a refresh is superseded. Polling
        // only after rows arrive cannot interrupt the full-table scan that
        // SQLite performs before returning the first aggregate row.
        sqlite3_progress_handler(db, 1_000, { _ in
            Task.isCancelled ? 1 : 0
        }, nil)
        defer {
            sqlite3_progress_handler(db, 0, nil, nil)
            sqlite3_close(db)
        }

        // opencode stores epoch MILLISECONDS in `time_created`, while the rest
        // of this module works in seconds.
        let sevenDaysAgoMs = Int64((now.timeIntervalSince1970 - 7 * 86_400) * 1000)
        let startOfTodayMs = Int64(Calendar.current.startOfDay(for: now)
            .timeIntervalSince1970 * 1000)

        // Grouping by (model, is_today) lets one pass fill both windows. The
        // `time_created` column is used for the range rather than the JSON's
        // own `$.time.created` so the filter can be evaluated without parsing
        // every row's document.
        let placeholders = Array(repeating: "?", count: providerIDs.count)
            .joined(separator: ", ")
        let sql = """
            SELECT json_extract(data, '$.providerID'),
                   json_extract(data, '$.modelID'),
                   CASE WHEN time_created >= ? THEN 1 ELSE 0 END,
                   sum(coalesce(json_extract(data, '$.tokens.input'), 0)),
                   sum(coalesce(json_extract(data, '$.tokens.output'), 0)),
                   sum(coalesce(json_extract(data, '$.tokens.reasoning'), 0)),
                   sum(coalesce(json_extract(data, '$.tokens.cache.read'), 0)),
                   sum(coalesce(json_extract(data, '$.tokens.cache.write'), 0)),
                   sum(coalesce(json_extract(data, '$.cost'), 0)),
                   count(*)
            FROM message
            WHERE time_created >= ?
              AND json_extract(data, '$.providerID') IN (\(placeholders))
              AND json_extract(data, '$.role') = 'assistant'
            GROUP BY 1, 2, 3
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startOfTodayMs)
        sqlite3_bind_int64(stmt, 2, sevenDaysAgoMs)
        for (offset, providerID) in providerIDs.enumerated() {
            sqlite3_bind_text(stmt, Int32(offset + 3), providerID, -1, SQLITE_TRANSIENT)
        }

        var scans = Dictionary(uniqueKeysWithValues:
            providerGroups.keys.map { ($0, OpencodeScan()) })
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            defer { stepResult = sqlite3_step(stmt) }
            guard !Task.isCancelled else { return nil }
            guard let providerC = sqlite3_column_text(stmt, 0) else { continue }
            let provider = String(cString: providerC)
            guard let group = groupByProvider[provider] else { continue }
            var scan = scans[group] ?? OpencodeScan()
            let rows = Int(sqlite3_column_int64(stmt, 9))
            // A turn with no `modelID` cannot be attributed to anything. Count
            // it rather than folding it into an arbitrary bucket.
            guard let modelC = sqlite3_column_text(stmt, 1) else {
                scan.skippedRows += rows
                scans[group] = scan
                continue
            }
            let model = String(cString: modelC)
            let isToday = sqlite3_column_int64(stmt, 2) == 1

            let input      = Int(sqlite3_column_int64(stmt, 3))
            let output     = Int(sqlite3_column_int64(stmt, 4))
            let reasoning  = Int(sqlite3_column_int64(stmt, 5))
            let cacheRead  = Int(sqlite3_column_int64(stmt, 6))
            let cacheWrite = Int(sqlite3_column_int64(stmt, 7))
            let cost       = sqlite3_column_double(stmt, 8)

            // Invariant 2: reasoning is billed as output and is not already
            // inside it. Invariant 1: input is already cache-exclusive, so it
            // maps straight across with no subtraction.
            let usage = ModelUsage(
                inputTokens: max(0, input),
                outputTokens: max(0, output) + max(0, reasoning),
                cacheReadTokens: max(0, cacheRead),
                cacheCreateTokens: max(0, cacheWrite))

            CostAggregator.add(usage, into: &scan.last7DaysByModel, model: model)
            scan.costLast7DaysByModel[model, default: 0] += cost
            if isToday {
                CostAggregator.add(usage, into: &scan.todayByModel, model: model)
                scan.costTodayByModel[model, default: 0] += cost
            }
            scans[group] = scan
        }
        // SQLITE_INTERRUPT is the expected cancellation path. Any other SQL
        // failure must also discard the partial aggregates.
        guard stepResult == SQLITE_DONE, !Task.isCancelled else { return nil }
        return scans
    }
}

// `sqlite3_bind_text` needs to copy the Swift string: the buffer it is handed
// does not outlive the call.
private let SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self)
