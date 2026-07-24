import Foundation

/// Walks `~/.codex/sessions/**/rollout-*.jsonl` and tallies per-model token
/// usage from Codex's `token_count` events, then converts to USD via
/// `PricingTable.openai`. This is the Codex counterpart to
/// `ClaudeSessionScanner` and supersedes `CodexLogScanner`.
///
/// Why this replaced the sqlite scanner: `CodexLogScanner` greps
/// `~/.codex/logs_2.sqlite` for `feedback_log_body` rows shaped
/// `model=X ... total_usage_tokens=N`. Current Codex builds no longer emit
/// that field — on a machine with months of daily Codex use the whole table
/// held 19 such rows, none in the last 7 days — so the Models breakdown for
/// OpenAI silently rendered empty. The real accounting moved into the rollout
/// transcripts, which are strictly richer: input/output/cached/reasoning split
/// per turn instead of one opaque total.
///
/// Wire shape (one JSON object per line):
///
/// ```
/// {"timestamp":"…","type":"turn_context","payload":{"model":"gpt-5.6-sol",…}}
/// {"timestamp":"…","type":"event_msg","payload":{"type":"token_count",
///   "info":{"last_token_usage":{"input_tokens":22140,"cached_input_tokens":9984,
///           "output_tokens":190,"reasoning_output_tokens":39,"total_tokens":22330},
///           "total_token_usage":{…}}}}
/// ```
///
/// Two invariants, checked against the rollouts on the author's machine
/// (21 files, 628 `token_count` events, 2026-07-24). Re-run the check with
/// `scripts/verify-codex-invariants.py` before trusting them on new data —
/// they are Codex's behaviour, not a contract it publishes.
///
///  - `total_tokens == input_tokens + output_tokens`, i.e. `cached_input_tokens`
///    is a **subset** of `input_tokens` and `reasoning_output_tokens` a subset
///    of `output_tokens`. Billing therefore needs `input - cached` at the fresh
///    input rate and `cached` at the cache-read rate; output is taken whole.
///    Held for 626/628 events. The two exceptions are context-window notices
///    carrying a non-zero `total_tokens` with an all-zero input/output split;
///    they have no billable breakdown, so `usage > 0` below drops them and
///    `droppedEmptyUsage` counts them rather than letting them vanish.
///  - Summing every `last_token_usage` across a file reproduces the file's
///    final `total_token_usage`, so per-turn deltas can be bucketed by
///    timestamp without double counting. (Using `total_token_usage` instead
///    would count the running total once per event.) Held on all 20 files
///    with data, including forked/resumed sessions, which do not replay turns
///    — for the three fields we bill. Codex folds the all-zero-split events
///    above into its running `total_tokens` while contributing nothing to the
///    breakdown, so that one derived field drifts by exactly their sum. We
///    never read it.
public enum CodexSessionScanner {
    public static func estimate(now: Date = .init(),
                                sessionsDir: URL? = nil) -> CostEstimate {
        estimateDetailed(now: now, sessionsDir: sessionsDir).estimate
    }

    /// Same scan, plus whether any billable usage was actually found.
    ///
    /// `CodexCost` needs to distinguish "the rollout scan saw nothing" from
    /// "the rollout scan saw real turns that happened to price to $0" (every
    /// model missing from `PricingTable`). Keying the source choice on dollars
    /// alone would silently hand the display to the dead sqlite scanner the
    /// moment OpenAI ships a model id we don't price yet.
    internal static func estimateDetailed(now: Date = .init(),
                                          sessionsDir: URL? = nil)
    -> (estimate: CostEstimate, sawUsage: Bool) {
        let sessions = sessionsDir ?? Paths.defaultCodexSessions()
        // `FileManager.enumerator` returns a NON-nil enumerator that yields
        // zero items for a missing directory, so a `guard let` on it is dead
        // code — the absent-directory case has to be tested explicitly or the
        // user who never ran Codex gets the same message as the user whose
        // sessions are simply older than the window.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDir),
              isDir.boolValue else {
            return (CostEstimate(usdToday: 0, usdLast7Days: 0,
                                 isApproximate: true,
                                 note: "No ~/.codex/sessions directory."), false)
        }
        guard let walker = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return (CostEstimate(usdToday: 0, usdLast7Days: 0,
                                 isApproximate: true,
                                 note: "Could not enumerate ~/.codex/sessions."), false)
        }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let sevenDaysAgo = startOfToday.addingTimeInterval(-7 * 86_400)

        var totalsToday: [String: ModelUsage] = [:]
        var totalsLast7: [String: ModelUsage] = [:]
        var filesScanned = 0
        var loss = ScanLoss()

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            if let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = attrs.contentModificationDate, mtime < sevenDaysAgo {
                continue
            }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            filesScanned += 1
            scan(data: data,
                 startOfToday: startOfToday,
                 sevenDaysAgo: sevenDaysAgo,
                 totalsToday: &totalsToday,
                 totalsLast7: &totalsLast7,
                 loss: &loss)
        }

        let (usdToday, breakdownToday) = CostAggregator.price(totals: totalsToday, table: PricingTable.openai)
        let (usdWeek, breakdownLast7) = CostAggregator.price(totals: totalsLast7, table: PricingTable.openai)
        // Every model we tallied but couldn't price contributes $0 to the
        // totals. Surfacing the ids is what turns "the number looks low" into
        // "OpenAI shipped a model id we don't have a rate for yet".
        let unpriced = Set(totalsLast7.keys)
            .filter { PricingTable.lookup($0, table: PricingTable.openai) == nil }
            .sorted()
        let sawUsage = !totalsLast7.isEmpty || !totalsToday.isEmpty
        let note: String?
        if filesScanned == 0 {
            note = "No recent Codex sessions found."
        } else if !unpriced.isEmpty {
            note = "Approximate — no price for \(unpriced.joined(separator: ", ")); " +
                   "those turns count as $0. Subscription users pay flat fee."
        } else if let lossNote = loss.note {
            note = "Approximate — \(lossNote) Subscription users pay flat fee."
        } else {
            note = "Approximate — based on pricing table; subscription users pay flat fee."
        }
        let estimate = CostEstimate(
            usdToday: usdToday,
            usdLast7Days: usdWeek,
            modelBreakdownToday: breakdownToday,
            modelBreakdownLast7Days: breakdownLast7,
            totalsByModel: totalsToday,
            computedAt: now,
            isApproximate: true,
            note: note
        )
        return (estimate, sawUsage)
    }

    // MARK: - Internal scanning

    /// Everything the scan had to throw away. Kept as one struct so adding a
    /// new loss category can't silently skip the note — the old code counted
    /// only unattributed turns, so a rollout whose every line failed to decode
    /// reported a confident "based on pricing table" with a total of zero.
    /// That is the exact failure this whole scanner exists to fix, and it
    /// would have been invisible again.
    internal struct ScanLoss: Equatable {
        var unattributedEvents = 0
        var decodeFailures = 0
        var undatedEvents = 0
        var droppedEmptyUsage = 0

        var note: String? {
            var parts: [String] = []
            if unattributedEvents > 0 { parts.append("\(unattributedEvents) turns had no model") }
            if decodeFailures > 0 { parts.append("\(decodeFailures) lines failed to parse") }
            if undatedEvents > 0 { parts.append("\(undatedEvents) turns had no usable timestamp") }
            if droppedEmptyUsage > 0 { parts.append("\(droppedEmptyUsage) turns reported no token split") }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Byte sequences we hunt for before paying the cost of JSON parsing. A
    /// rollout is mostly `response_item` payloads (the actual conversation),
    /// so this rejects the large majority of lines without invoking
    /// `JSONDecoder` — same trick as `ClaudeSessionScanner`.
    private static let tokenCountMarker = Data("\"token_count\"".utf8)
    private static let turnContextMarker = Data("\"turn_context\"".utf8)
    /// The session-level model marker. It must be in the prefilter too, not
    /// just handled in the decoder: a rollout whose only model marker is a
    /// `thread_settings_applied` line would otherwise have every one of its
    /// turns fall through to `unattributedEvents`.
    private static let threadSettingsMarker = Data("\"thread_settings_applied\"".utf8)
    private static let newline: UInt8 = 0x0a

    /// Typed shape for the two line kinds we care about. Everything else in
    /// the payload is discarded cheaply by `JSONDecoder`.
    private struct RolloutLine: Decodable {
        let timestamp: String?
        let type: String?
        let payload: Payload?

        struct Payload: Decodable {
            /// Present on `type == "turn_context"` lines.
            let model: String?
            /// Payload discriminator for `type == "event_msg"` lines.
            let type: String?
            let info: Info?
            let thread_settings: ThreadSettings?

            struct ThreadSettings: Decodable {
                let model: String?
            }

            struct Info: Decodable {
                let last_token_usage: Usage?

                struct Usage: Decodable {
                    let input_tokens: Int?
                    let cached_input_tokens: Int?
                    let output_tokens: Int?
                }
            }
        }
    }

    /// Internal-visibility so tests can drive synthetic rollout JSONL through
    /// it without standing up a `~/.codex/sessions` tree. Production path goes
    /// through `estimate(now:sessionsDir:)`.
    ///
    /// A rollout file is a single session, and the model can only change when
    /// a new `turn_context` is written — so we attribute each `token_count` to
    /// the most recent model seen. Codex writes `turn_context` before the
    /// first `token_count` in every rollout observed, but a truncated or
    /// mid-write file could break that; usage seen before any model is buffered
    /// and flushed onto the first model the file names, and dropped (counted
    /// into `loss.unattributedEvents`) only if the file never names one.
    internal static func scan(
        data: Data,
        startOfToday: Date,
        sevenDaysAgo: Date,
        totalsToday: inout [String: ModelUsage],
        totalsLast7: inout [String: ModelUsage],
        loss: inout ScanLoss
    ) {
        var currentModel: String?
        var pending: [(usage: ModelUsage, timestamp: Date?)] = []
        var undated = 0

        func record(_ usage: ModelUsage, at ts: Date?, model: String) {
            guard let ts else {
                // Fail-safe, mirroring ClaudeSessionScanner: a record we can't
                // place in time counts into both buckets rather than vanishing.
                // It inflates "today" by up to the 7-day total, so it has to be
                // disclosed — ClaudeSessionScanner says so in its note and this
                // one now does too.
                undated += 1
                CostAggregator.add(usage, into: &totalsToday, model: model)
                CostAggregator.add(usage, into: &totalsLast7, model: model)
                return
            }
            if ts >= startOfToday { CostAggregator.add(usage, into: &totalsToday, model: model) }
            if ts >= sevenDaysAgo { CostAggregator.add(usage, into: &totalsLast7, model: model) }
        }

        var offset = data.startIndex
        let end = data.endIndex
        while offset < end {
            let lineEnd = data[offset..<end].firstIndex(of: newline) ?? end
            defer { offset = lineEnd < end ? lineEnd + 1 : end }
            guard lineEnd > offset else { continue }
            let line = data[offset..<lineEnd]

            guard line.range(of: tokenCountMarker) != nil
                    || line.range(of: turnContextMarker) != nil
                    || line.range(of: threadSettingsMarker) != nil
            else { continue }

            let parsed: RolloutLine
            do {
                parsed = try SharedCoders.decoder.decode(RolloutLine.self, from: Data(line))
            } catch {
                // A line that passed the byte prefilter but won't decode is a
                // schema drift signal — exactly how the sqlite scanner died
                // silently. Count it so the note can say so.
                loss.decodeFailures += 1
                continue
            }
            guard let payload = parsed.payload else { continue }

            // Model markers, gated on the line's own discriminator. Without the
            // type check any line carrying a `model` key — a settings echo, a
            // future event kind — could silently re-attribute every following
            // turn. `turn_context` is authoritative and per-turn;
            // `thread_settings_applied` is the session-level fallback that
            // shows up when settings change without opening a new turn.
            let modelMarker: String? = {
                if parsed.type == "turn_context" { return payload.model }
                if payload.type == "thread_settings_applied" { return payload.thread_settings?.model }
                return nil
            }()
            if let model = modelMarker, !model.isEmpty {
                currentModel = model
                if !pending.isEmpty {
                    for entry in pending { record(entry.usage, at: entry.timestamp, model: model) }
                    pending.removeAll()
                }
            }

            guard payload.type == "token_count",
                  let last = payload.info?.last_token_usage
            else { continue }

            // Clamp BOTH ends. `min` alone caps the ceiling and leaves the
            // floor open, which is not a theoretical gap: a line declaring
            // `cached_input_tokens: -5000` made `input - cached` grow the
            // fresh-input bucket instead of shrinking it (5.5x over-report),
            // and `input_tokens: Int.max` with a negative cached made the
            // subtraction TRAP — Swift's `-` does not wrap, so one malformed
            // line killed the whole menu-bar app with SIGTRAP. With both
            // operands clamped to `0...input`, the subtraction cannot overflow
            // and cannot go negative.
            let input = max(0, last.input_tokens ?? 0)
            let cached = min(max(0, last.cached_input_tokens ?? 0), input)
            let usage = ModelUsage(
                // `cached_input_tokens` is a subset of `input_tokens`, so the
                // fresh-input bucket is the difference.
                inputTokens: input - cached,
                // Includes `reasoning_output_tokens`; OpenAI bills reasoning at
                // the output rate, so it must not be added a second time.
                outputTokens: max(0, last.output_tokens ?? 0),
                cacheReadTokens: cached
            )
            guard usage.inputTokens > 0 || usage.outputTokens > 0 || usage.cacheReadTokens > 0
            else {
                // Codex emits context-window notices with a non-zero
                // `total_tokens` but an all-zero split. There is nothing
                // billable to attribute, but the tokens aren't nothing either.
                loss.droppedEmptyUsage += 1
                continue
            }

            let ts = parsed.timestamp.flatMap(ISO8601Parsing.parse)
            if let model = currentModel {
                record(usage, at: ts, model: model)
            } else {
                pending.append((usage, ts))
            }
        }

        // File ended without ever naming a model — surface the loss instead of
        // silently attributing it to a guess.
        loss.unattributedEvents += pending.count
        loss.undatedEvents += undated
    }
}
