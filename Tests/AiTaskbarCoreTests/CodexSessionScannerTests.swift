import Testing
import Foundation
import SQLite3
@testable import AiTaskbarCore

@Suite("CodexSessionScanner — rollout JSONL parsing")
struct CodexSessionScannerTests {
    /// One `turn_context` line naming `model`, then one `token_count` event.
    private func rollout(model: String,
                         timestamp: String,
                         input: Int,
                         cached: Int,
                         output: Int,
                         reasoning: Int = 0) -> String {
        let ctx = """
        {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"\(model)","reasoning_effort":"high"}}
        """
        let tc = """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(input + output)},"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(input + output)}}}}
        """
        return ctx + "\n" + tc + "\n"
    }

    private func scan(_ jsonl: String,
                      now: Date = Date(timeIntervalSince1970: 1_784_000_000))
    -> (today: [String: ModelUsage], week: [String: ModelUsage],
        loss: CodexSessionScanner.ScanLoss) {
        let startOfToday = Calendar.current.startOfDay(for: now)
        var today: [String: ModelUsage] = [:]
        var week: [String: ModelUsage] = [:]
        var loss = CodexSessionScanner.ScanLoss()
        CodexSessionScanner.scan(
            data: Data(jsonl.utf8),
            startOfToday: startOfToday,
            sevenDaysAgo: startOfToday.addingTimeInterval(-7 * 86_400),
            totalsToday: &today,
            totalsLast7: &week,
            loss: &loss
        )
        return (today, week, loss)
    }

    /// The load-bearing invariant: `cached_input_tokens` is a SUBSET of
    /// `input_tokens`, so the fresh-input bucket must be the difference. If a
    /// refactor ever adds them instead, this catches it — 1M input with 400k
    /// cached is 600k fresh, not 1M and not 1.4M.
    @Test("cached input is subtracted from input, never added")
    func cached_is_subset_of_input() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let result = scan(rollout(model: "gpt-5.6-sol",
                                  timestamp: iso.string(from: now),
                                  input: 1_000_000,
                                  cached: 400_000,
                                  output: 100_000),
                          now: now)
        let usage = result.today["gpt-5.6-sol"]
        #expect(usage?.inputTokens == 600_000)
        #expect(usage?.cacheReadTokens == 400_000)
        #expect(usage?.outputTokens == 100_000)
        #expect(usage?.cacheCreateTokens == 0)
    }

    /// `reasoning_output_tokens` is a subset of `output_tokens` and is billed
    /// at the output rate — it must not be counted a second time.
    @Test("reasoning tokens are not added on top of output tokens")
    func reasoning_not_double_counted() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let result = scan(rollout(model: "gpt-5.6",
                                  timestamp: iso.string(from: now),
                                  input: 1000,
                                  cached: 0,
                                  output: 500,
                                  reasoning: 300),
                          now: now)
        #expect(result.today["gpt-5.6"]?.outputTokens == 500)
    }

    /// End-to-end money check against the gpt-5.6 long-context tier ($8 in /
    /// $30 out / $0.8 cache read): 0.6M fresh + 0.1M out + 0.4M cached = $8.12.
    @Test("priced total matches the gpt-5.6 tier exactly")
    func prices_to_expected_usd() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let result = scan(rollout(model: "gpt-5.6-sol",
                                  timestamp: iso.string(from: now),
                                  input: 1_000_000,
                                  cached: 400_000,
                                  output: 100_000),
                          now: now)
        let (usd, byModel) = CostAggregator.price(totals: result.today,
                                                  table: PricingTable.openai)
        #expect(abs(usd - 8.12) < 0.000_001)
        #expect(byModel["gpt-5.6-sol"] != nil)
    }

    @Test("long-context pricing starts only above 272K input tokens")
    func long_context_pricing_boundary() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = iso.string(from: now)

        let atThreshold = scan(rollout(
            model: "gpt-5.6-sol", timestamp: timestamp,
            input: 272_000, cached: 0, output: 1_000_000), now: now)
        let aboveThreshold = scan(rollout(
            model: "gpt-5.6-sol", timestamp: timestamp,
            input: 272_001, cached: 0, output: 1_000_000), now: now)
        let (standardUSD, _) = CostAggregator.price(
            totals: atThreshold.today, table: PricingTable.openai)
        let (longUSD, _) = CostAggregator.price(
            totals: aboveThreshold.today, table: PricingTable.openai)

        #expect(abs(standardUSD - 21.088) < 0.000_001)
        #expect(abs(longUSD - 32.176_008) < 0.000_001)
    }

    @Test("GPT-5.6 Cyber long-context pricing starts only above 272K input tokens")
    func cyber_long_context_pricing_boundary() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = iso.string(from: now)

        let atThreshold = scan(rollout(
            model: "gpt-5.6-cyber", timestamp: timestamp,
            input: 272_000, cached: 0, output: 100_000), now: now)
        let aboveThreshold = scan(rollout(
            model: "gpt-5.6-cyber", timestamp: timestamp,
            input: 272_001, cached: 0, output: 100_000), now: now)
        let (standardUSD, _) = CostAggregator.price(
            totals: atThreshold.today, table: PricingTable.openai)
        let (longUSD, _) = CostAggregator.price(
            totals: aboveThreshold.today, table: PricingTable.openai)

        #expect(abs(standardUSD - 10.9) < 0.000_001)
        #expect(abs(longUSD - 18.050_025) < 0.000_001)
    }

    /// Each event carries the delta for its own turn, and summing the deltas
    /// reproduces the session total. Two events in one file must accumulate.
    @Test("per-turn deltas accumulate across events in one file")
    func deltas_accumulate() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let jsonl = rollout(model: "gpt-5.5", timestamp: ts,
                            input: 1000, cached: 0, output: 100)
            + rollout(model: "gpt-5.5", timestamp: ts,
                      input: 2000, cached: 0, output: 200)
        let result = scan(jsonl, now: now)
        #expect(result.today["gpt-5.5"]?.inputTokens == 3000)
        #expect(result.today["gpt-5.5"]?.outputTokens == 300)
    }

    /// A mid-session model switch must re-attribute subsequent turns; the
    /// earlier turns stay on the earlier model.
    @Test("model switch mid-file re-attributes later turns")
    func model_switch_reattributes() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let jsonl = rollout(model: "gpt-5.5", timestamp: ts,
                            input: 1000, cached: 0, output: 100)
            + rollout(model: "gpt-5.4", timestamp: ts,
                      input: 7000, cached: 0, output: 700)
        let result = scan(jsonl, now: now)
        #expect(result.today["gpt-5.5"]?.inputTokens == 1000)
        #expect(result.today["gpt-5.4"]?.inputTokens == 7000)
    }

    /// Usage older than today lands in the 7-day bucket only.
    @Test("older turns fill the week bucket but not today")
    func older_turns_skip_today() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let twoDaysAgo = iso.string(from: now.addingTimeInterval(-2 * 86_400))
        let result = scan(rollout(model: "gpt-5.5", timestamp: twoDaysAgo,
                                  input: 1000, cached: 0, output: 100),
                          now: now)
        #expect(result.today["gpt-5.5"] == nil)
        #expect(result.week["gpt-5.5"]?.inputTokens == 1000)
    }

    /// A `token_count` before any model marker is buffered, then flushed onto
    /// the first model the file names — not dropped, not mis-attributed.
    @Test("usage preceding the first turn_context flushes onto that model")
    func pre_model_usage_is_flushed() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let orphan = """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":550}}}}
        """
        let jsonl = orphan + "\n" + rollout(model: "gpt-5.5", timestamp: ts,
                                            input: 1000, cached: 0, output: 100)
        let result = scan(jsonl, now: now)
        #expect(result.today["gpt-5.5"]?.inputTokens == 1500)
        #expect(result.loss.unattributedEvents == 0)
    }

    /// A file that never names a model must surface the loss rather than
    /// silently guessing an attribution.
    @Test("usage with no model anywhere in the file is counted as unattributed")
    func unattributed_usage_is_reported() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let orphan = """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":550}}}}
        """
        let result = scan(orphan + "\n", now: now)
        #expect(result.today.isEmpty)
        #expect(result.loss.unattributedEvents == 1)
    }

    /// `thread_settings_applied` is the session-level fallback marker Codex
    /// writes when settings change without opening a new turn.
    @Test("thread_settings_applied supplies the model when turn_context is absent")
    func thread_settings_supplies_model() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let settings = """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.4","service_tier":"default"}}}
        """
        let tc = """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":800,"cached_input_tokens":0,"output_tokens":80,"reasoning_output_tokens":0,"total_tokens":880}}}}
        """
        let result = scan(settings + "\n" + tc + "\n", now: now)
        #expect(result.today["gpt-5.4"]?.inputTokens == 800)
    }

    /// The conversation body — `response_item`, `agent_message`, etc. — is the
    /// bulk of a rollout and must be skipped without contributing usage.
    @Test("non-usage rollout lines contribute nothing")
    func conversation_lines_are_ignored() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let noise = """
        {"timestamp":"\(ts)","type":"response_item","payload":{"type":"message","role":"assistant"}}
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"task_started","turn_id":"abc"}}
        not even json
        """
        let result = scan(noise + "\n", now: now)
        #expect(result.today.isEmpty)
        #expect(result.week.isEmpty)
        #expect(result.loss.unattributedEvents == 0)
    }

    /// Regression: `min(cached, input)` alone caps the ceiling and leaves the
    /// floor open. A negative `cached_input_tokens` used to GROW the
    /// fresh-input bucket (`1000 - (-5000) = 6000`, a 5.5x over-report) and
    /// leave a negative cache-read count that credits money back.
    @Test("negative cached tokens cannot inflate fresh input")
    func negative_cached_cannot_inflate() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let result = scan(rollout(model: "gpt-5.5",
                                  timestamp: iso.string(from: now),
                                  input: 1000,
                                  cached: -5000,
                                  output: 100),
                          now: now)
        #expect(result.today["gpt-5.5"]?.inputTokens == 1000)
        #expect(result.today["gpt-5.5"]?.cacheReadTokens == 0)
    }

    /// Regression: Swift's `-` TRAPS on overflow rather than wrapping, so
    /// `Int.max - (-1)` used to kill the whole menu-bar app with SIGTRAP from
    /// a single malformed line. If this test ever regresses it does not fail —
    /// it crashes the test runner, which is itself the signal.
    @Test("Int.max input with negative cached does not trap")
    func int_max_does_not_trap() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let result = scan(rollout(model: "gpt-5.5",
                                  timestamp: iso.string(from: now),
                                  input: Int.max,
                                  cached: -1,
                                  output: 0),
                          now: now)
        #expect(result.today["gpt-5.5"]?.inputTokens == Int.max)
    }

    /// Regression: two `Int.max` turns summed used to trap inside
    /// `CostAggregator.add`. Saturation keeps an absurd-but-visible number
    /// instead of a dead process.
    @Test("summing two Int.max turns saturates instead of trapping")
    func aggregate_saturates() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let jsonl = rollout(model: "gpt-5.5", timestamp: ts, input: Int.max, cached: 0, output: 0)
            + rollout(model: "gpt-5.5", timestamp: ts, input: Int.max, cached: 0, output: 0)
        let result = scan(jsonl, now: now)
        #expect(result.today["gpt-5.5"]?.inputTokens == Int.max)
    }

    /// Regression: a line that clears the byte prefilter but fails to decode
    /// used to `continue` with no counter — the exact silent-drift failure
    /// mode that killed the sqlite scanner this file replaces.
    @Test("undecodable line that passes the prefilter is counted")
    func decode_failure_is_counted() {
        let jsonl = "{\"type\":\"turn_context\",\"payload\":{\"model\":42}}\n"
        let result = scan(jsonl)
        #expect(result.loss.decodeFailures == 1)
    }

    /// Regression: a `model` key on a line that is NOT a model marker must not
    /// re-attribute subsequent turns.
    @Test("model key on a non-marker line does not re-attribute")
    func stray_model_key_is_ignored() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let stray = """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.4-pro","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":11}}}}
        """
        let jsonl = rollout(model: "gpt-5.5", timestamp: ts,
                            input: 1000, cached: 0, output: 100) + stray + "\n"
        let result = scan(jsonl, now: now)
        #expect(result.today["gpt-5.4-pro"] == nil)
        #expect(result.today["gpt-5.5"]?.inputTokens == 1010)
    }

    /// Codex emits context-window notices carrying a non-zero `total_tokens`
    /// with an all-zero split. They have nothing billable, but dropping them
    /// without a counter is how token loss becomes invisible.
    @Test("all-zero token split is dropped but counted")
    func empty_usage_is_counted() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let result = scan(rollout(model: "gpt-5.5",
                                  timestamp: iso.string(from: now),
                                  input: 0, cached: 0, output: 0),
                          now: now)
        #expect(result.today.isEmpty)
        #expect(result.loss.droppedEmptyUsage == 1)
    }

    /// A malformed line claiming more cached tokens than total input must not
    /// produce a negative fresh-input count (which would credit the user).
    @Test("cached exceeding input clamps to zero fresh input")
    func cached_over_input_clamps() {
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let result = scan(rollout(model: "gpt-5.5",
                                  timestamp: iso.string(from: now),
                                  input: 100,
                                  cached: 900,
                                  output: 10),
                          now: now)
        #expect(result.today["gpt-5.5"]?.inputTokens == 0)
        #expect(result.today["gpt-5.5"]?.cacheReadTokens == 100)
    }
}

@Suite("CodexSessionScanner.estimate over a synthetic sessions tree")
struct CodexSessionScannerEstimateTests {
    private func makeTree(files: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-codex-sessions-\(UUID().uuidString)")
        let day = root.appendingPathComponent("2026/07/24", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        for (i, contents) in files.enumerated() {
            try Data(contents.utf8).write(
                to: day.appendingPathComponent("rollout-\(i).jsonl"))
        }
        return root
    }

    @Test("estimate walks the tree and prices today + week")
    func estimate_walks_tree() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let jsonl = """
        {"timestamp":"\(ts)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":400000,"output_tokens":100000,"reasoning_output_tokens":0,"total_tokens":1100000}}}}

        """
        let root = try makeTree(files: [jsonl])
        defer { try? FileManager.default.removeItem(at: root) }

        let est = CodexSessionScanner.estimate(now: now, sessionsDir: root)
        #expect(abs(est.usdToday - 8.12) < 0.000_001)
        #expect(est.usdLast7Days >= est.usdToday)
        #expect(est.modelBreakdownToday["gpt-5.6-sol"] != nil)
        #expect(est.isApproximate)
    }

    @Test("estimate on a missing directory returns the no-directory note")
    func estimate_missing_dir() {
        let missing = URL(fileURLWithPath: "/tmp/ai-taskbar-codex-missing-\(UUID().uuidString)")
        let est = CodexSessionScanner.estimate(sessionsDir: missing)
        #expect(est.usdToday == 0)
        expectTrue(est.note?.contains("No ~/.codex/sessions") ?? false)
    }

    @Test("estimate on an empty tree reports no recent sessions")
    func estimate_empty_tree() throws {
        let root = try makeTree(files: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let est = CodexSessionScanner.estimate(sessionsDir: root)
        #expect(est.usdToday == 0)
        expectTrue(est.note?.contains("No recent Codex sessions") ?? false)
    }

    /// The two "nothing to show" states must not produce the same message.
    /// `FileManager.enumerator` hands back a non-nil enumerator for a missing
    /// directory, so the original `guard let walker` was dead code and the
    /// user who never installed Codex got the same note as the user whose
    /// sessions are merely older than the window.
    @Test("missing directory and empty directory give different notes")
    func missing_and_empty_are_distinguishable() throws {
        let missing = URL(fileURLWithPath: "/tmp/ai-taskbar-codex-missing-\(UUID().uuidString)")
        let empty = try makeTree(files: [])
        defer { try? FileManager.default.removeItem(at: empty) }
        let missingNote = CodexSessionScanner.estimate(sessionsDir: missing).note
        let emptyNote = CodexSessionScanner.estimate(sessionsDir: empty).note
        #expect(missingNote != emptyNote)
        expectTrue(missingNote?.contains("No ~/.codex/sessions") ?? false)
    }

    /// A model absent from `PricingTable` prices to $0 but is NOT absent data.
    /// The note has to name it, otherwise "the number looks low" is
    /// indistinguishable from "OpenAI shipped an id we don't price yet".
    @Test("unpriced model is named in the note instead of vanishing")
    func unpriced_model_is_disclosed() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let jsonl = """
        {"timestamp":"\(ts)","type":"turn_context","payload":{"model":"gpt-7-unreleased"}}
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":900000,"cached_input_tokens":0,"output_tokens":50000,"reasoning_output_tokens":0,"total_tokens":950000}}}}

        """
        let root = try makeTree(files: [jsonl])
        defer { try? FileManager.default.removeItem(at: root) }
        let est = CodexSessionScanner.estimate(now: now, sessionsDir: root)
        #expect(est.usdToday == 0)
        #expect(est.unpricedModelsToday == Set(["gpt-7-unreleased"]))
        #expect(est.unpricedModelsLast7Days == Set(["gpt-7-unreleased"]))
        expectTrue(est.note?.contains("gpt-7-unreleased") ?? false)
    }

    /// Opt-in only. Reading the developer's real `~/.codex/sessions` makes the
    /// result depend on whoever runs it: it passes vacuously on a machine with
    /// no Codex history, and on a machine WITH history a crash in the scanner
    /// would take down the test runner rather than fail a test — so as a gate
    /// it is both non-hermetic and unable to report the thing it exists to
    /// catch. The synthetic-tree tests above cover the same code
    /// deterministically. Run this one deliberately:
    ///
    ///     CODEX_REAL_SESSIONS=1 swift test --filter estimate_real_dir
    @Test("estimate against the real ~/.codex/sessions must not throw",
          .enabled(if: ProcessInfo.processInfo.environment["CODEX_REAL_SESSIONS"] == "1"))
    func estimate_real_dir_is_safe() {
        let est = CodexSessionScanner.estimate()
        #expect(est.isApproximate)
        #expect(est.usdToday >= 0)
        #expect(est.usdLast7Days >= est.usdToday)
    }
}

@Suite("CodexCost source selection")
struct CodexCostTests {
    /// The session scanner wins whenever it priced anything — the sqlite path
    /// describes the same turns on installs that still write it, so summing
    /// the two would double-count.
    @Test("session data wins and is not summed with sqlite data")
    func session_wins_over_sqlite() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-codex-cost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        {"timestamp":"\(ts)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":400000,"output_tokens":100000,"reasoning_output_tokens":0,"total_tokens":1100000}}}}

        """.utf8).write(to: root.appendingPathComponent("rollout-0.jsonl"))

        let est = CodexCost.estimate(now: now,
                                     sessionsDir: root,
                                     dbPath: "/tmp/definitely-missing-\(UUID().uuidString).sqlite")
        #expect(abs(est.usdToday - 8.12) < 0.000_001)
    }

    /// The test above cannot actually detect summing, because its sqlite side
    /// is empty — anything plus zero is itself. This one populates BOTH
    /// sources and pins the result to the sessions-only figure, so a future
    /// `usdToday + fromLogs.usdToday` fails here instead of shipping.
    @Test("both sources populated: result is sessions-only, never the sum")
    func populated_sqlite_is_not_added() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-codex-both-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        {"timestamp":"\(ts)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000000,"cached_input_tokens":400000,"output_tokens":100000,"reasoning_output_tokens":0,"total_tokens":1100000}}}}

        """.utf8).write(to: root.appendingPathComponent("rollout-0.jsonl"))

        // Legacy sqlite with real, differently-priced usage.
        let db = try makeLegacyDB(nowSeconds: Int(now.timeIntervalSince1970),
                                  body: "model=gpt-5 total_usage_tokens=2000000")
        defer { try? FileManager.default.removeItem(at: db) }
        let legacyOnly = CodexLogScanner.estimate(now: now, dbPath: db.path)
        #expect(legacyOnly.usdToday > 0, "sqlite side must really have data")

        let est = CodexCost.estimate(now: now, sessionsDir: root, dbPath: db.path)
        #expect(abs(est.usdToday - 8.12) < 0.000_001)
        #expect(abs(est.usdToday - (8.12 + legacyOnly.usdToday)) > 0.1, "must not be the sum")
    }

    /// Regression: choosing the source by DOLLARS meant a model missing from
    /// `PricingTable` (cost $0) silently handed the display to the dead sqlite
    /// scanner — showing legacy numbers while the live source held real turns.
    @Test("unpriced rollout usage still wins over populated sqlite")
    func unpriced_sessions_beat_sqlite() throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-codex-unpriced-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        {"timestamp":"\(ts)","type":"turn_context","payload":{"model":"gpt-7-unreleased"}}
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":900000,"cached_input_tokens":0,"output_tokens":50000,"reasoning_output_tokens":0,"total_tokens":950000}}}}

        """.utf8).write(to: root.appendingPathComponent("rollout-0.jsonl"))
        let db = try makeLegacyDB(nowSeconds: Int(now.timeIntervalSince1970),
                                  body: "model=gpt-5 total_usage_tokens=2000000")
        defer { try? FileManager.default.removeItem(at: db) }

        let est = CodexCost.estimate(now: now, sessionsDir: root, dbPath: db.path)
        #expect(est.usdToday == 0, "live source has data; legacy must not take over")
        expectTrue(est.note?.contains("gpt-7-unreleased") ?? false)
    }

    /// With no session data at all, the note should come from the session
    /// scanner (the path that matters on current Codex builds), not from a
    /// complaint about a sqlite file that no longer carries usage.
    @Test("empty sources fall through to the session scanner's note")
    func empty_sources_report_session_note() {
        let est = CodexCost.estimate(
            sessionsDir: URL(fileURLWithPath: "/tmp/ai-taskbar-none-\(UUID().uuidString)"),
            dbPath: "/tmp/ai-taskbar-none-\(UUID().uuidString).sqlite")
        #expect(est.usdToday == 0)
        expectTrue(est.note?.contains("~/.codex/sessions") ?? false)
    }

    @Test("unknown-only legacy usage remains visible when sessions are empty")
    func unpriced_legacy_fallback_remains_visible() throws {
        let now = Date()
        let db = try makeLegacyDB(
            nowSeconds: Int(now.timeIntervalSince1970),
            body: "model=gpt-7-unreleased total_usage_tokens=1000")
        defer { try? FileManager.default.removeItem(at: db) }

        let est = CodexCost.estimate(
            now: now,
            sessionsDir: URL(fileURLWithPath: "/tmp/ai-taskbar-none-\(UUID().uuidString)"),
            dbPath: db.path)

        #expect(est.modelBreakdownToday["gpt-7-unreleased"] == 0)
        #expect(est.unpricedModelsToday == Set(["gpt-7-unreleased"]))
        #expect(est.unpricedModelsLast7Days == Set(["gpt-7-unreleased"]))
        #expect(est.hasDisplayData)
        expectTrue(est.note?.localizedCaseInsensitiveContains("price unavailable") ?? false)
    }

    private func makeLegacyDB(nowSeconds: Int, body: String) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-legacy-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        sqlite3_open(tmp.path, &db)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE logs (ts INTEGER, feedback_log_body TEXT)", nil, nil, nil)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO logs (ts, feedback_log_body) VALUES (?, ?)", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, Int64(nowSeconds - 60))
        _ = body.withCString { sqlite3_bind_text(stmt, 2, $0, -1, nil) }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return tmp
    }
}
