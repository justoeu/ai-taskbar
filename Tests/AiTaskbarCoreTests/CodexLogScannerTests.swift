import Testing
import Foundation
import SQLite3
@testable import AiTaskbarCore

@Suite("CodexLogScanner.parse + estimate fallback")
struct CodexLogScannerTests {
    @Test("parses model + total_usage_tokens from typical log body")
    func parses_typical_body() {
        let body = "session=abc model=gpt-5-codex total_usage_tokens=4500 latency_ms=320"
        let parsed = CodexLogScanner.parse(body: body)
        #expect(parsed?.model == "gpt-5-codex")
        #expect(parsed?.tokens == 4500)
    }

    @Test("parse returns nil when model is missing")
    func parse_returns_nil_when_no_model() {
        let body = "total_usage_tokens=100"
        #expect(CodexLogScanner.parse(body: body) == nil)
    }

    @Test("parse returns nil when total_usage_tokens is missing")
    func parse_returns_nil_when_no_tokens() {
        let body = "model=gpt-5"
        #expect(CodexLogScanner.parse(body: body) == nil)
    }

    @Test("parse rejects non-numeric token values")
    func parse_rejects_non_numeric_tokens() {
        let body = "model=gpt-5 total_usage_tokens=abc"
        #expect(CodexLogScanner.parse(body: body) == nil)
    }

    @Test("parse handles start-of-string match (no preceding whitespace)")
    func parse_handles_start_of_string() {
        let body = "model=gpt-5 total_usage_tokens=42"
        #expect(CodexLogScanner.parse(body: body)?.tokens == 42)
    }

    @Test("estimate falls back gracefully when sqlite file missing")
    func estimate_returns_zero_when_no_db() {
        // The default path scan when ~/.codex/logs_2.sqlite is absent should
        // return an estimate with zero cost and a "no sqlite" note. We can't
        // delete the user's real file, but if it's absent on this machine
        // we get the no-file path; if it's present we get a populated one.
        // Either way, the call must not throw.
        let est = CodexLogScanner.estimate()
        #expect(est.isApproximate)
    }
}

@Suite("CodexLogScanner via synthetic SQLite", .serialized)
struct CodexLogScannerSQLiteTests {
    /// Build a minimal sqlite file mimicking the Codex schema and run the
    /// scan-and-price code path. We can't redirect Codex's hardcoded
    /// `~/.codex/logs_2.sqlite` lookup from here, but we exercise the
    /// SQLite open/prepare/step happy path enough to push coverage.
    private func buildSyntheticDB(rows: [(ts: Int, body: String)]) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-codex-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        sqlite3_open(tmp.path, &db)
        defer { sqlite3_close(db) }
        sqlite3_exec(db,
            "CREATE TABLE logs (ts INTEGER, feedback_log_body TEXT)",
            nil, nil, nil)
        let insertSQL = "INSERT INTO logs (ts, feedback_log_body) VALUES (?, ?)"
        for row in rows {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, Int64(row.ts))
            row.body.withCString { sqlite3_bind_text(stmt, 2, $0, -1, nil) }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        return tmp
    }

    @Test("estimate(dbPath:) walks synthetic logs and prices today + week")
    func estimate_walks_synthetic_logs() throws {
        let now = Date()
        let nowSec = Int(now.timeIntervalSince1970)
        let twoDaysAgo = nowSec - 2 * 86_400
        let url = try buildSyntheticDB(rows: [
            (nowSec - 60,  "model=gpt-5 total_usage_tokens=1000000"),  // today
            (twoDaysAgo,   "model=gpt-5-mini total_usage_tokens=500000"),  // 7d only
            // Row without usage_tokens — must be ignored.
            (nowSec, "model=gpt-5 other=stuff"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let est = CodexLogScanner.estimate(now: now, dbPath: url.path)
        #expect(est.usdToday > 0, "today bucket should fill")
        #expect(est.usdLast7Days >= est.usdToday, "week ≥ today")
        // gpt-5 entry only — gpt-5-mini didn't fall into today.
        #expect(est.modelBreakdownToday["gpt-5"] != nil)
        #expect(est.modelBreakdownToday["gpt-5-mini"] == nil)
        #expect(est.modelBreakdownLast7Days["gpt-5-mini"] != nil)
    }

    @Test("estimate returns zero when synthetic DB has no matching rows")
    func estimate_zero_when_no_matching_rows() throws {
        let url = try buildSyntheticDB(rows: [
            (Int(Date().timeIntervalSince1970), "no relevant fields here"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let est = CodexLogScanner.estimate(dbPath: url.path)
        #expect(est.usdToday == 0)
        #expect(est.usdLast7Days == 0)
    }

    @Test("estimate gracefully fails when sqlite cannot open")
    func estimate_handles_bad_sqlite_file() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-codex-bad-\(UUID().uuidString).sqlite")
        try Data("not a valid sqlite file".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let est = CodexLogScanner.estimate(dbPath: tmp.path)
        #expect(est.usdToday == 0)
    }
}
