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
    /// Tokens per local calendar day of the 7-day window (`CostWindow`
    /// days, oldest first), for the Analytics chart. Dollars are left out on
    /// purpose: opencode cost is never added to a vendor's figures.
    public var daily: [DailyModelUsage] = []
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
///
/// ## Two storage layouts (opencode 1.x and 2.x)
///
/// 1.x writes turns to `message`: role in `$.role`, model in `$.modelID` and
/// `$.providerID`. 2.x (measured on v2.1.4, 2026-10-25) writes them to
/// `session_message`: role in the `type` column, model in `$.model.id` and
/// `$.model.providerID`; `tokens` and `cost` keep the 1.x shape and all three
/// semantics above (re-measured: 635 of 1653 turns have `reasoning > output`,
/// and turns with ~200k cache reads keep `input` in the hundreds). The layout
/// is read from the database itself (`Schema.detect`), not from an installed
/// binary's version, which need not be the one that wrote the file. Without
/// this, a 2.x database failed `prepare` and every card silently lost its
/// opencode rows.
public enum OpencodeScanner {
    /// The storage layout of the database being read.
    enum Schema: Equatable {
        /// opencode 1.x: `message` only.
        case v1
        /// opencode 2.x: `session_message` only.
        case v2
        /// Both tables, as an in-place upgrade may leave them. Whether 2.x
        /// copied the old turns over is not knowable from the schema, so
        /// `message` contributes only turns OLDER than the first
        /// `session_message` turn: copied rows are then never counted twice,
        /// and turns left behind in `message` are not dropped.
        case both

        /// nil = neither table: an unknown layout, read as unavailable.
        static func detect(_ db: OpaquePointer?) -> Schema? {
            let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('message', 'session_message')"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            var names = Set<String>()
            var step = sqlite3_step(stmt)
            while step == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 0) { names.insert(String(cString: name)) }
                step = sqlite3_step(stmt)
            }
            guard step == SQLITE_DONE else { return nil }
            switch (names.contains("message"), names.contains("session_message")) {
            case (true, true): return .both
            case (false, true): return .v2
            case (true, false): return .v1
            case (false, false): return nil
            }
        }

        // Assistant turns since `?2` (seven days ago, ms) as
        // (provider, model, time_created, data). Constant SQL only: every
        // value is bound, nothing from the database is interpolated.
        private static let v2Turns = """
            SELECT json_extract(data, '$.model.providerID') AS provider,
                   json_extract(data, '$.model.id') AS model, time_created, data
            FROM session_message
            WHERE time_created >= ?2 AND type = 'assistant'
            """
        private static let v1Turns = """
            SELECT json_extract(data, '$.providerID') AS provider,
                   json_extract(data, '$.modelID') AS model, time_created, data
            FROM message
            WHERE time_created >= ?2 AND json_extract(data, '$.role') = 'assistant'
            """

        var turnsSQL: String {
            switch self {
            case .v1: return Self.v1Turns
            case .v2: return Self.v2Turns
            case .both:
                // `min(time_created)` is served by the time index.
                return Self.v2Turns + "\nUNION ALL\n" + Self.v1Turns + """

                      AND time_created < (SELECT coalesce(min(time_created), 9223372036854775807)
                                          FROM session_message)
                    """
            }
        }
    }

    /// Why a scan did or did not produce rows. The `scan` overloads collapse
    /// both non-`scanned` cases to nil; callers that must tell "opencode is
    /// not installed" (genuinely no rows) from "the read failed" (keep what
    /// was shown) use `scanOutcome` instead of re-probing the path, which
    /// could race with the scan's own check (CQ-MAE-003).
    public enum Outcome: Sendable, Equatable {
        /// No database file at the path.
        case notInstalled
        /// Cancelled, an alias mapped to two groups, no provider aliases, or
        /// an SQLite open / prepare / step failure. Any partial aggregate is
        /// discarded.
        case unavailable
        case scanned([String: OpencodeScan])
    }

    public static func defaultDatabasePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    /// Scans usage for `providerID` (opencode's own vendor key: `openai`,
    /// `xai`, `anthropic`, …). Returns nil for every non-`scanned` `Outcome`
    /// (not installed, or unavailable); use `scanOutcome` to tell them apart.
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
    /// the opencode provider aliases billed to that vendor. nil for every
    /// non-`scanned` `Outcome`.
    public static func scan(now: Date = .init(),
                            providerGroups: [String: [String]],
                            dbPath: String? = nil) -> [String: OpencodeScan]? {
        if case .scanned(let scans) = scanOutcome(now: now, providerGroups: providerGroups,
                                                  dbPath: dbPath) {
            return scans
        }
        return nil
    }

    /// `scan(providerGroups:)` with the reason for a missing result kept.
    public static func scanOutcome(now: Date = .init(),
                                   providerGroups: [String: [String]],
                                   dbPath: String? = nil) -> Outcome {
        guard !Task.isCancelled else { return .unavailable }
        var groupByProvider: [String: String] = [:]
        for group in providerGroups.keys.sorted() {
            for provider in Set(providerGroups[group, default: []]).sorted()
            where !provider.isEmpty {
                // An alias cannot be attributed to two billing vendors.
                guard groupByProvider[provider] == nil else { return .unavailable }
                groupByProvider[provider] = group
            }
        }
        let providerIDs = groupByProvider.keys.sorted()
        guard !providerIDs.isEmpty else { return .unavailable }
        let path = dbPath ?? defaultDatabasePath()
        guard FileManager.default.fileExists(atPath: path) else { return .notInstalled }

        var db: OpaquePointer?
        // Read-only, and never create: this database belongs to another
        // application that may be running right now. FULLMUTEX because the
        // handle is opened from whichever queue the refresh lands on.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return .unavailable
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
        let window = CostWindow(now: now)
        let sevenDaysAgoMs = Int64(window.startOfLast7Days.timeIntervalSince1970 * 1000)
        let startOfTodayMs = Int64(window.startOfToday.timeIntervalSince1970 * 1000)
        // Local day starts, oldest first (DST-safe, from the one `CostWindow`).
        let days = window.calendarDays()
        guard days.count == 7 else { return .unavailable }
        let dayStartsMs = days.map { Int64($0.timeIntervalSince1970 * 1000) }

        guard let schema = Schema.detect(db) else { return .unavailable }

        // Grouping by (model, is_today) lets one pass fill both windows. The
        // `time_created` column is used for the range rather than the JSON's
        // own `$.time.created` so the filter can be evaluated without parsing
        // every row's document.
        // Numbered parameters: ?1 start of today (day slot 6), ?2 seven days
        // ago (slot 0), ?3…?7 the starts of slots 1…5, ?8… the provider
        // aliases (the `.both` layout uses ?2 twice). Column 3 is the day
        // slot, so one pass fills today, the week and every day.
        let placeholders = providerIDs.indices.map { "?\($0 + 8)" }
            .joined(separator: ", ")
        let sql = """
            SELECT provider, model,
                   CASE WHEN time_created >= ?1 THEN 6 WHEN time_created >= ?7 THEN 5
                        WHEN time_created >= ?6 THEN 4 WHEN time_created >= ?5 THEN 3
                        WHEN time_created >= ?4 THEN 2 WHEN time_created >= ?3 THEN 1
                        ELSE 0 END,
                   sum(coalesce(json_extract(data, '$.tokens.input'), 0)),
                   sum(coalesce(json_extract(data, '$.tokens.output'), 0)),
                   sum(coalesce(json_extract(data, '$.tokens.reasoning'), 0)),
                   sum(coalesce(json_extract(data, '$.tokens.cache.read'), 0)),
                   sum(coalesce(json_extract(data, '$.tokens.cache.write'), 0)),
                   sum(coalesce(json_extract(data, '$.cost'), 0)),
                   count(*)
            FROM (\(schema.turnsSQL))
            WHERE provider IN (\(placeholders))
            GROUP BY 1, 2, 3
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .unavailable
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, startOfTodayMs)
        sqlite3_bind_int64(stmt, 2, sevenDaysAgoMs)
        for slot in 1...5 {
            sqlite3_bind_int64(stmt, Int32(slot + 2), dayStartsMs[slot])
        }
        for (offset, providerID) in providerIDs.enumerated() {
            sqlite3_bind_text(stmt, Int32(offset + 8), providerID, -1, SQLITE_TRANSIENT)
        }

        var dailyTotals = Dictionary(uniqueKeysWithValues:
            providerGroups.keys.map { ($0, Array(repeating: [String: ModelUsage](), count: 7)) })
        var scans = Dictionary(uniqueKeysWithValues:
            providerGroups.keys.map { ($0, OpencodeScan()) })
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            defer { stepResult = sqlite3_step(stmt) }
            guard !Task.isCancelled else { return .unavailable }
            guard let providerC = sqlite3_column_text(stmt, 0) else { continue }
            let provider = String(cString: providerC)
            guard let group = groupByProvider[provider] else { continue }
            var scan = scans[group] ?? OpencodeScan()
            let rows = Int(sqlite3_column_int64(stmt, 9))
            // A turn with no model id cannot be attributed to anything. Count
            // it rather than folding it into an arbitrary bucket.
            guard let modelC = sqlite3_column_text(stmt, 1) else {
                scan.skippedRows += rows
                scans[group] = scan
                continue
            }
            let model = String(cString: modelC)
            let slot = Int(sqlite3_column_int64(stmt, 2))
            let isToday = slot == 6

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
                // Each column fits Int64, their sum need not: saturate.
                outputTokens: CostAggregator.saturatingAdd(max(0, output), max(0, reasoning)),
                cacheReadTokens: max(0, cacheRead),
                cacheCreateTokens: max(0, cacheWrite))

            if (0..<7).contains(slot) {
                CostAggregator.add(usage, into: &dailyTotals[group, default: Array(repeating: [:], count: 7)][slot],
                                   model: model)
            }
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
        guard stepResult == SQLITE_DONE, !Task.isCancelled else { return .unavailable }
        for group in scans.keys {
            let slots = dailyTotals[group] ?? []
            scans[group]?.daily = days.enumerated().map { slot, day in
                DailyModelUsage(date: day, usageByModel: slot < slots.count ? slots[slot] : [:])
            }
        }
        return .scanned(scans)
    }
}

// `sqlite3_bind_text` needs to copy the Swift string: the buffer it is handed
// does not outlive the call.
private let SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self)
