import Foundation

/// Walks `~/.claude/projects/*/*.jsonl` and tallies per-model token usage from
/// assistant messages, then converts to USD via PricingTable.
///
/// Performance notes (vs the original `[String: Any]` impl):
///  - Byte-level prefilter (`"usage":{`) discards user/tool/summary lines
///    without invoking JSONDecoder. Typically rejects 80–90% of lines.
///  - Each surviving line is decoded into a typed `AssistantLine` struct
///    instead of `[String: Any]`, eliminating NSDictionary bridging churn.
///  - Files are memory-mapped (`.mappedIfSafe`) so large transcripts don't
///    cause `LineStream.buffer.removeSubrange` O(n²) shifts.
public enum ClaudeSessionScanner {
    /// Process-wide memo so a refresh only re-parses files that changed.
    /// Static because the scanner is a stateless enum called from a detached
    /// task; the memo is the one thing that must survive between calls.
    private static let memo = ScanMemo()

    public static func estimate(now: Date = .init(),
                                projectsDir: URL? = nil) -> CostEstimate {
        let projects: URL = projectsDir ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        // `FileManager.enumerator` hands back a NON-nil enumerator that yields
        // zero items for a missing directory, so a bare `guard let` on it is
        // dead code: the "never ran Claude Code" user fell through to the same
        // "no recent sessions" note as someone whose transcripts are merely
        // older than the window. The absent-directory case has to be tested
        // explicitly. (The `guard let` stays as a genuine failure path — it
        // fires when the URL is unreadable rather than absent.)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDir),
              isDir.boolValue else {
            return CostEstimate(usdToday: 0, usdLast7Days: 0,
                                isApproximate: true,
                                note: "No ~/.claude/projects directory.")
        }
        guard let walker = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return CostEstimate(usdToday: 0, usdLast7Days: 0,
                                isApproximate: true,
                                note: "Could not enumerate ~/.claude/projects.")
        }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let sevenDaysAgo = startOfToday.addingTimeInterval(-7 * 86_400)

        var totalsToday: [String: ModelUsage] = [:]
        var totalsLast7: [String: ModelUsage] = [:]
        var filesScanned = 0
        var unparseableTimestamps = 0

        var seenPaths = Set<String>()
        for case let url as URL in walker {
            // Cooperate with cancellation. A full scan is 2-6 s of CPU over
            // hundreds of files; without this a refresh that the scheduler
            // has already superseded runs to completion anyway, burning a
            // cooperative-pool thread the next one needs. Checked per file
            // rather than per line — file granularity is fine at this size
            // and keeps the inner loop branch-free.
            if Task.isCancelled { break }
            guard url.pathExtension == "jsonl" else { continue }
            let attrs = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let mtime = attrs?.contentModificationDate, mtime < sevenDaysAgo {
                continue
            }
            filesScanned += 1
            seenPaths.insert(url.path)

            // Replay the memo when the file is byte-for-byte the same as last
            // pass. Transcripts are append-only, so on a steady-state refresh
            // nearly every file takes this branch and never gets read.
            if let mtime = attrs?.contentModificationDate,
               let size = attrs?.fileSize,
               let hit = memo.lookup(path: url.path, size: size,
                                     mtime: mtime, day: startOfToday) {
                for (model, usage) in hit.today {
                    CostAggregator.add(usage, into: &totalsToday, model: model)
                }
                for (model, usage) in hit.week {
                    CostAggregator.add(usage, into: &totalsLast7, model: model)
                }
                continue
            }

            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            // Scan into per-file buckets so the file's own contribution can be
            // memoized; merge into the running totals afterwards.
            var fileToday: [String: ModelUsage] = [:]
            var fileWeek: [String: ModelUsage] = [:]
            scan(data: data,
                 startOfToday: startOfToday,
                 sevenDaysAgo: sevenDaysAgo,
                 totalsToday: &fileToday,
                 totalsLast7: &fileWeek,
                 unparseableTimestamps: &unparseableTimestamps)
            for (model, usage) in fileToday {
                CostAggregator.add(usage, into: &totalsToday, model: model)
            }
            for (model, usage) in fileWeek {
                CostAggregator.add(usage, into: &totalsLast7, model: model)
            }
            if let mtime = attrs?.contentModificationDate, let size = attrs?.fileSize {
                memo.store(path: url.path,
                           entry: ScanMemo.Entry(size: size, mtime: mtime,
                                                 computedForDay: startOfToday,
                                                 today: fileToday, week: fileWeek))
            }
        }
        // Files that aged out of the window stop being tracked.
        memo.retain(paths: seenPaths)

        let (usdToday, breakdownToday) = CostAggregator.price(totals: totalsToday, table: PricingTable.anthropic)
        let (usdWeek, breakdownLast7) = CostAggregator.price(totals: totalsLast7, table: PricingTable.anthropic)
        let unpricedToday = Set(totalsToday.keys.filter {
            PricingTable.lookup($0, table: PricingTable.anthropic) == nil
        })
        let unpricedLast7 = Set(totalsLast7.keys.filter {
            PricingTable.lookup($0, table: PricingTable.anthropic) == nil
        })
        let note: String?
        if filesScanned == 0 {
            note = "No recent Claude sessions found."
        } else {
            var details: [String] = []
            if !unpricedLast7.isEmpty {
                details.append("price unavailable for \(unpricedLast7.sorted().joined(separator: ", ")); those turns are excluded from cost totals")
            }
            if unparseableTimestamps > 0 {
                details.append("\(unparseableTimestamps) records had unparseable timestamps (counted into today)")
            }
            if details.isEmpty { details.append("based on pricing table") }
            note = "Approximate — \(details.joined(separator: "; ")). " +
                   "Subscription users pay flat fee."
        }
        return CostEstimate(
            usdToday: usdToday,
            usdLast7Days: usdWeek,
            modelBreakdownToday: breakdownToday,
            modelBreakdownLast7Days: breakdownLast7,
            totalsByModel: totalsToday,
            computedAt: now,
            isApproximate: true,
            note: note,
            unpricedModelsToday: unpricedToday,
            unpricedModelsLast7Days: unpricedLast7
        )
    }

    // MARK: - Internal scanning

    /// Byte sequences we hunt for before paying the cost of JSON parsing.
    private static let usageMarker = Data("\"usage\":{".utf8)
    private static let typeAssistantMarker = Data("\"role\":\"assistant\"".utf8)
    private static let newline: UInt8 = 0x0a

    /// Typed shape for a single assistant JSONL line. Only the fields we
    /// actually need — `JSONDecoder` discards everything else cheaply.
    private struct AssistantLine: Decodable {
        let timestamp: String?
        let message: Message?
        struct Message: Decodable {
            let model: String?
            let usage: Usage?
            struct Usage: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_creation_input_tokens: Int?
                let cache_read_input_tokens: Int?
                let cache_creation: CacheCreation?

                struct CacheCreation: Decodable {
                    let ephemeral_5m_input_tokens: Int?
                    let ephemeral_1h_input_tokens: Int?
                }
            }
        }
    }

    /// Internal-visibility (so tests can drive synthetic JSONL through it
    /// without standing up the whole `~/.claude/projects` walker).
    /// Production path goes through `estimate(now:)`.
    internal static func scan(
        data: Data,
        startOfToday: Date,
        sevenDaysAgo: Date,
        totalsToday: inout [String: ModelUsage],
        totalsLast7: inout [String: ModelUsage],
        unparseableTimestamps: inout Int
    ) {
        var offset = data.startIndex
        let end = data.endIndex
        while offset < end {
            // Find next newline within the remaining slice.
            let lineEnd = data[offset..<end].firstIndex(of: newline) ?? end
            defer { offset = lineEnd < end ? lineEnd + 1 : end }
            guard lineEnd > offset else { continue }
            let line = data[offset..<lineEnd]

            // Cheap byte prefilter: assistant messages are the only ones
            // carrying a `usage` block. Reject everything else without JSON.
            guard line.range(of: usageMarker) != nil else { continue }
            guard line.range(of: typeAssistantMarker) != nil else { continue }

            // Decode straight from the slice: `Data(line)` copied every
            // surviving line (62.8 MB per refresh on a real transcript set)
            // for nothing — JSONDecoder accepts any DataProtocol slice.
            let parsed: AssistantLine
            do {
                parsed = try SharedCoders.decoder.decode(AssistantLine.self, from: line)
            } catch {
                continue
            }
            guard let msg = parsed.message,
                  let model = msg.model,
                  let usage = msg.usage
            else { continue }

            let statedCacheCreate = max(0, usage.cache_creation_input_tokens ?? 0)
            let detailed5m = max(0, usage.cache_creation?.ephemeral_5m_input_tokens ?? 0)
            let detailed1h = max(0, usage.cache_creation?.ephemeral_1h_input_tokens ?? 0)
            let detailedTotal = CostAggregator.saturatingAdd(detailed5m, detailed1h)
            let cacheCreateTotal = usage.cache_creation_input_tokens == nil
                ? detailedTotal : statedCacheCreate
            let cacheCreate1h = min(detailed1h, cacheCreateTotal)
            // Any unclassified remainder uses the five-minute rate. Older
            // transcript lines have only `cache_creation_input_tokens`.
            let cacheCreate5m = cacheCreateTotal - cacheCreate1h
            let modelUsage = ModelUsage(
                inputTokens: usage.input_tokens ?? 0,
                outputTokens: usage.output_tokens ?? 0,
                cacheReadTokens: usage.cache_read_input_tokens ?? 0,
                cacheCreateTokens: cacheCreate5m,
                cacheCreate1hTokens: cacheCreate1h
            )

            let ts = parsed.timestamp.flatMap(ISO8601Parsing.parse)
            if let ts {
                if ts >= startOfToday { CostAggregator.add(modelUsage, into: &totalsToday, model: model) }
                if ts >= sevenDaysAgo { CostAggregator.add(modelUsage, into: &totalsLast7, model: model) }
            } else {
                // Fail-safe: count missing-timestamp records into today.
                // We surface the count in the note so users can spot drift.
                CostAggregator.add(modelUsage, into: &totalsToday, model: model)
                CostAggregator.add(modelUsage, into: &totalsLast7, model: model)
                unparseableTimestamps += 1
            }
        }
    }
}
