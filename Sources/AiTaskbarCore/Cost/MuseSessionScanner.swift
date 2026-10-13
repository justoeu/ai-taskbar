import Foundation

/// Walks the Muse CLI's session logs
/// (`~/.local/share/muse/sessions/YYYY/MM/DD/<uuid>/session.jsonl`) and
/// tallies per-model token usage from completed model steps.
///
/// Token semantics — measured against real logs, do NOT generalize from the
/// other scanners (`docs/SDD-meta-muse.md` §9):
/// - `input_tokens` **includes** cached tokens (like Codex), so the cache
///   read is subtracted out before filling `ModelUsage.inputTokens`.
/// - `reasoning_tokens` is a subset of `output_tokens` and is never added.
/// - Only `model_completed` and `automated_review_completed` events count.
///   `resource_usage_sampled`, `goal_usage_attribution` and
///   `record.quantity` are rollups/telemetry over the same steps; counting
///   them too would double every total.
///
/// Meta publishes no prices (the local model catalog carries `cost: null`),
/// so every model is reported unpriced and USD stays 0 — tokens are the
/// whole story here, never dollars.
public enum MuseSessionScanner {
    private static let memo = ScanMemo()

    /// Bucket attribution when an event carries no model: tokens are real
    /// even when the model label is missing, so they are kept, not dropped.
    public static let unknownModel = "unknown"

    public static func estimate(now: Date = .init(),
                                sessionsDir: URL? = nil) -> CostEstimate {
        estimate(now: now, sessionsDir: sessionsDir, memo: memo)
    }

    /// Memo seam: tests pass their own `ScanMemo`, like the other scanners.
    internal static func estimate(now: Date,
                                  sessionsDir: URL?,
                                  memo: ScanMemo) -> CostEstimate {
        let root = sessionsDir ?? Paths.museSessionsDir()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else {
            return CostEstimate(usdToday: 0, usdLast7Days: 0,
                                isApproximate: true,
                                note: "No Muse sessions directory.")
        }
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return CostEstimate(usdToday: 0, usdLast7Days: 0,
                                isApproximate: true,
                                note: "Could not enumerate Muse sessions.")
        }

        let window = CostWindow(now: now)
        var totalsToday: [String: ModelUsage] = [:]
        var totalsLast7: [String: ModelUsage] = [:]
        var dailyTotals: [[String: ModelUsage]] = Array(repeating: [:], count: 7)
        var filesScanned = 0
        var drift = 0
        var seenPaths = Set<String>()

        for case let url as URL in walker {
            if Task.isCancelled { break }
            guard url.lastPathComponent == "session.jsonl" else { continue }
            let attrs = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let mtime = attrs?.contentModificationDate, mtime < window.startOfLast7Days {
                continue
            }
            filesScanned += 1
            seenPaths.insert(url.path)

            if let mtime = attrs?.contentModificationDate,
               let size = attrs?.fileSize,
               let hit = memo.lookup(path: url.path, size: size,
                                     mtime: mtime, day: window.startOfToday) {
                merge(hit.today, into: &totalsToday)
                merge(hit.week, into: &totalsLast7)
                for (slot, models) in hit.daily.enumerated() where slot < 7 {
                    merge(models, into: &dailyTotals[slot])
                }
                continue
            }

            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            var fileToday: [String: ModelUsage] = [:]
            var fileWeek: [String: ModelUsage] = [:]
            var fileDaily: [[String: ModelUsage]] = Array(repeating: [:], count: 7)
            scanLines(data: data, window: window,
                      totalsToday: &fileToday, totalsLast7: &fileWeek,
                      dailyTotals: &fileDaily, drift: &drift)
            merge(fileToday, into: &totalsToday)
            merge(fileWeek, into: &totalsLast7)
            for (slot, models) in fileDaily.enumerated() where slot < 7 {
                merge(models, into: &dailyTotals[slot])
            }
            if let mtime = attrs?.contentModificationDate, let size = attrs?.fileSize {
                memo.store(path: url.path,
                           entry: ScanMemo.Entry(size: size, mtime: mtime,
                                                 computedForDay: window.startOfToday,
                                                 today: fileToday, week: fileWeek,
                                                 daily: fileDaily))
            }
        }
        if !Task.isCancelled { memo.retain(paths: seenPaths) }

        // Zero-dollar breakdown rows for every discovered model, like the
        // priced scanners emit for unpriced models: without them
        // `hasDisplayData` is false and the card footer never renders.
        let zeroBreakdown: ([String: ModelUsage]) -> [String: Double] = {
            Dictionary(uniqueKeysWithValues: $0.keys.map { ($0, 0.0) })
        }
        let dailyUsage = window.calendarDays().enumerated().map { slot, day in
            DailyModelUsage(date: day,
                            usageByModel: slot < dailyTotals.count ? dailyTotals[slot] : [:],
                            costByModel: zeroBreakdown(
                                slot < dailyTotals.count ? dailyTotals[slot] : [:]))
        }
        let note: String?
        if filesScanned == 0 {
            note = "No recent Muse sessions found."
        } else if drift > 0 {
            note = "Tokens only — Meta publishes no prices. "
                 + "\(drift) malformed usage records were skipped."
        } else {
            note = "Tokens only — Meta publishes no prices."
        }
        return CostEstimate(
            usdToday: 0,
            usdLast7Days: 0,
            modelBreakdownToday: zeroBreakdown(totalsToday),
            modelBreakdownLast7Days: zeroBreakdown(totalsLast7),
            totalsByModel: totalsToday,
            computedAt: now,
            isApproximate: true,
            note: note,
            unpricedModelsToday: Set(totalsToday.keys),
            unpricedModelsLast7Days: Set(totalsLast7.keys),
            dailyUsage: dailyUsage
        )
    }

    private static func merge(_ source: [String: ModelUsage],
                              into target: inout [String: ModelUsage]) {
        for (model, usage) in source {
            CostAggregator.add(usage, into: &target, model: model)
        }
    }

    // MARK: - Line scanning

    private static let completedMarker = Data("\"model_completed\"".utf8)
    private static let reviewMarker = Data("\"automated_review_completed\"".utf8)
    private static let newline: UInt8 = 0x0a

    /// Envelope of one session-log line. Only the fields we need; prompt and
    /// tool payloads on neighbouring lines are never decoded.
    private struct Envelope: Decodable {
        let recorded_at: Int64?
        let payload: Payload?
        struct Payload: Decodable {
            let event: Event?
            struct Event: Decodable {
                let kind: String?
                let model: String?
                let usage: Usage?
                struct Usage: Decodable {
                    let input_tokens: Int?
                    let output_tokens: Int?
                    let cached_tokens: Int?
                    let cache_read_tokens: Int?
                    let cache_write_tokens: Int?
                }
            }
        }
    }

    /// Internal-visibility seam so tests can drive synthetic JSONL without
    /// standing up the whole sessions tree (same pattern as the Claude
    /// scanner's `scan`).
    internal static func scan(data: Data,
                              window: CostWindow,
                              totalsToday: inout [String: ModelUsage],
                              totalsLast7: inout [String: ModelUsage],
                              dailyTotals: inout [[String: ModelUsage]]) {
        var drift = 0
        scanLines(data: data, window: window,
                  totalsToday: &totalsToday, totalsLast7: &totalsLast7,
                  dailyTotals: &dailyTotals, drift: &drift)
    }

    private static func scanLines(data: Data,
                                  window: CostWindow,
                                  totalsToday: inout [String: ModelUsage],
                                  totalsLast7: inout [String: ModelUsage],
                                  dailyTotals: inout [[String: ModelUsage]],
                                  drift: inout Int) {
        let decoder = JSONDecoder()
        for line in data.split(separator: newline, omittingEmptySubsequences: true) {
            let slice = Data(line)
            guard slice.range(of: completedMarker) != nil
                    || slice.range(of: reviewMarker) != nil else { continue }
            guard let envelope = try? decoder.decode(Envelope.self, from: slice),
                  let event = envelope.payload?.event,
                  let kind = event.kind,
                  kind == "model_completed" || kind == "automated_review_completed"
            else { drift += 1; continue }
            guard let usage = event.usage else { continue }  // a completed event without usage is not drift (SDD §16)
            guard let recordedAt = envelope.recorded_at else { drift += 1; continue }
            let date = Date(timeIntervalSince1970: TimeInterval(recordedAt) / 1_000_000)
            guard let offset = window.dayOffset(for: date) else { continue }

            let cacheRead = max(0, usage.cache_read_tokens ?? usage.cached_tokens ?? 0)
            let modelUsage = ModelUsage(
                inputTokens: max(0, (usage.input_tokens ?? 0) - cacheRead),
                outputTokens: max(0, usage.output_tokens ?? 0),
                cacheReadTokens: cacheRead,
                cacheCreateTokens: max(0, usage.cache_write_tokens ?? 0))
            let model = event.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bucket = (model?.isEmpty ?? true) ? unknownModel : model!

            CostAggregator.add(modelUsage, into: &totalsLast7, model: bucket)
            if offset == 0 {
                CostAggregator.add(modelUsage, into: &totalsToday, model: bucket)
            }
            if let slot = window.slotIndex(for: date), slot < dailyTotals.count {
                CostAggregator.add(modelUsage, into: &dailyTotals[slot], model: bucket)
            }
        }
    }
}
