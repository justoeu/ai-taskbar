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
        estimate(now: now, projectsDir: projectsDir, memo: memo)
    }

    /// One account's transcripts: `key` is the account's `storageKey`.
    public struct Root: Sendable, Equatable {
        public let key: String
        public let projectsDir: URL
        public init(key: String, projectsDir: URL) {
            self.key = key
            self.projectsDir = projectsDir
        }
    }

    /// Machine-wide total plus the same figures per account.
    public struct MultiEstimate: Sendable {
        public let total: CostEstimate
        public let byAccount: [String: CostEstimate]
        public init(total: CostEstimate, byAccount: [String: CostEstimate]) {
            self.total = total
            self.byAccount = byAccount
        }
    }

    /// Scans every account's `projects/` in one pass. Each line is
    /// attributed to the account whose folder holds it; responses are
    /// deduped by `(message.id, requestId)` ACROSS roots too, so a copy of
    /// the same response in two folders is billed once (to the root of the
    /// copy that was kept).
    public static func estimate(now: Date = .init(), roots: [Root]) -> MultiEstimate {
        estimate(now: now, roots: roots, memo: memo)
    }

    /// Memo seam: tests pass their own `ScanMemo` so they can observe what a
    /// scan keeps or evicts without racing other suites on the shared one.
    internal static func estimate(now: Date,
                                  projectsDir: URL?,
                                  memo: ScanMemo) -> CostEstimate {
        let projects: URL = projectsDir ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        return estimate(now: now, roots: [Root(key: VendorId.anthropic.rawValue, projectsDir: projects)],
                        memo: memo).total
    }

    internal static func estimate(now: Date, roots: [Root], memo: ScanMemo) -> MultiEstimate {
        let window = CostWindow(now: now)
        var total = Accumulator()
        var perRoot: [String: Accumulator] = [:]
        // Responses keyed by (message.id, requestId), deduped across every
        // file of every root in the window — memo replays included — before
        // aggregation. The value remembers which root kept the response.
        var keyedAll: [String: (root: String, record: ScanMemo.KeyedUsage)] = [:]
        var seenPaths = Set<String>()
        var anyRootPresent = false
        var enumerationFailed = false

        for root in roots {
            if Task.isCancelled { break }
            var acc = perRoot[root.key] ?? Accumulator()
            switch walk(root.projectsDir, window: window, memo: memo, into: &acc, seenPaths: &seenPaths) {
            case .missing: break
            case .unreadable: anyRootPresent = true; enumerationFailed = true
            case .scanned: anyRootPresent = true
            }
            // Keys are already unique within a root; across roots the copy
            // with the larger output wins, and a tie keeps the earlier root.
            for (key, record) in acc.keyed {
                if let kept = keyedAll[key], kept.record.usage.outputTokens >= record.usage.outputTokens {
                    continue
                }
                keyedAll[key] = (root.key, record)
            }
            acc.keyed = [:]
            total.absorbUnkeyed(acc)
            perRoot[root.key] = acc
        }
        // Files that aged out of the window stop being tracked. Only after a
        // complete walk: a cancelled one saw a partial set, and pruning to it
        // would evict every file it had not reached yet (LEAK-FAN-002).
        if !Task.isCancelled { memo.retain(paths: seenPaths) }
        for (_, kept) in keyedAll {
            total.fold(kept.record)
            perRoot[kept.root]?.fold(kept.record)
        }

        // The old wording names `~/.claude`, true only for the default
        // account alone; an extra account's folder is somewhere else.
        let folder = roots.count == 1 && roots[0].key == VendorId.anthropic.rawValue
            ? "~/.claude/projects" : "Claude projects"
        let emptyNote: String? = enumerationFailed && total.filesScanned == 0
            ? "Could not enumerate \(folder)."
            : (anyRootPresent ? nil : "No \(folder) directory.")
        let totalEstimate = emptyNote.map {
            CostEstimate(usdToday: 0, usdLast7Days: 0, isApproximate: true, note: $0)
        } ?? makeEstimate(total, now: now, window: window)
        var byAccount: [String: CostEstimate] = [:]
        for root in roots {
            byAccount[root.key] = makeEstimate(perRoot[root.key] ?? Accumulator(), now: now, window: window)
        }
        return MultiEstimate(total: totalEstimate, byAccount: byAccount)
    }

    /// Running totals for one scope (the machine, or one account).
    private struct Accumulator {
        var totalsToday: [String: ModelUsage] = [:]
        var totalsLast7: [String: ModelUsage] = [:]
        var dailyTotals: [[String: ModelUsage]] = Array(repeating: [:], count: 7)
        var keyed: [String: ScanMemo.KeyedUsage] = [:]
        var filesScanned = 0
        var unparseableTimestamps = 0

        mutating func add(today: [String: ModelUsage], week: [String: ModelUsage],
                          daily: [[String: ModelUsage]]) {
            for (model, usage) in today { CostAggregator.add(usage, into: &totalsToday, model: model) }
            for (model, usage) in week { CostAggregator.add(usage, into: &totalsLast7, model: model) }
            for (slot, models) in daily.enumerated() where slot < 7 {
                for (model, usage) in models {
                    CostAggregator.add(usage, into: &dailyTotals[slot], model: model)
                }
            }
        }

        /// Everything but the keyed responses, which are folded only after
        /// the cross-root dedupe.
        mutating func absorbUnkeyed(_ other: Accumulator) {
            add(today: other.totalsToday, week: other.totalsLast7, daily: other.dailyTotals)
            filesScanned += other.filesScanned
            unparseableTimestamps += other.unparseableTimestamps
        }

        mutating func fold(_ record: ScanMemo.KeyedUsage) {
            if record.inToday { CostAggregator.add(record.usage, into: &totalsToday, model: record.model) }
            if record.inWeek { CostAggregator.add(record.usage, into: &totalsLast7, model: record.model) }
            if record.dayOffset >= 0 && record.dayOffset <= 6 && dailyTotals.count == 7 {
                CostAggregator.add(record.usage, into: &dailyTotals[6 - Int(record.dayOffset)], model: record.model)
            }
        }
    }

    private enum WalkResult { case missing, unreadable, scanned }

    /// Walks one `projects/` folder into `acc`: unkeyed lines are added to
    /// the totals, keyed responses land in `acc.keyed` (deduped within the
    /// folder) for the caller's cross-root dedupe.
    private static func walk(_ projects: URL, window: CostWindow, memo: ScanMemo,
                             into acc: inout Accumulator, seenPaths: inout Set<String>) -> WalkResult {
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
            return .missing
        }
        guard let walker = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return .unreadable
        }
        let startOfToday = window.startOfToday
        let sevenDaysAgo = window.startOfLast7Days

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
            acc.filesScanned += 1
            seenPaths.insert(url.path)

            // Replay the memo when the file is byte-for-byte the same as last
            // pass. Transcripts are append-only, so on a steady-state refresh
            // nearly every file takes this branch and never gets read.
            if let mtime = attrs?.contentModificationDate,
               let size = attrs?.fileSize,
               let hit = memo.lookup(path: url.path, size: size,
                                     mtime: mtime, day: startOfToday) {
                acc.add(today: hit.today, week: hit.week, daily: hit.daily)
                for (key, record) in hit.keyed { mergeKeyed(record, key: key, into: &acc.keyed) }
                continue
            }

            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            // Scan into per-file buckets so the file's own contribution can be
            // memoized; merge into the running totals afterwards.
            var fileToday: [String: ModelUsage] = [:]
            var fileWeek: [String: ModelUsage] = [:]
            var fileDaily: [[String: ModelUsage]] = Array(repeating: [:], count: 7)
            var fileKeyed: [String: ScanMemo.KeyedUsage] = [:]
            scanLines(data: data,
                      startOfToday: startOfToday,
                      sevenDaysAgo: sevenDaysAgo,
                      totalsToday: &fileToday,
                      totalsLast7: &fileWeek,
                      dailyTotals: &fileDaily,
                      keyed: &fileKeyed,
                      unparseableTimestamps: &acc.unparseableTimestamps)
            for (key, record) in fileKeyed { mergeKeyed(record, key: key, into: &acc.keyed) }
            acc.add(today: fileToday, week: fileWeek, daily: fileDaily)
            if let mtime = attrs?.contentModificationDate, let size = attrs?.fileSize {
                memo.store(path: url.path,
                           entry: ScanMemo.Entry(size: size, mtime: mtime,
                                                 computedForDay: startOfToday,
                                                 today: fileToday, week: fileWeek,
                                                 daily: fileDaily,
                                                 keyed: fileKeyed))
            }
        }
        return .scanned
    }

    private static func makeEstimate(_ acc: Accumulator, now: Date, window: CostWindow) -> CostEstimate {
        let (usdToday, breakdownToday) = CostAggregator.price(totals: acc.totalsToday, table: PricingTable.anthropic)
        let (usdWeek, breakdownLast7) = CostAggregator.price(totals: acc.totalsLast7, table: PricingTable.anthropic)
        let calendarDays = window.calendarDays()
        var dailyUsage: [DailyModelUsage] = []
        for (slot, day) in calendarDays.enumerated() {
            let dayModels = slot < acc.dailyTotals.count ? acc.dailyTotals[slot] : [:]
            let (_, dayBreakdown) = CostAggregator.price(totals: dayModels, table: PricingTable.anthropic)
            dailyUsage.append(DailyModelUsage(date: day, usageByModel: dayModels, costByModel: dayBreakdown))
        }

        let unpricedToday = Set(acc.totalsToday.keys.filter {
            PricingTable.lookup($0, table: PricingTable.anthropic) == nil
        })
        let unpricedLast7 = Set(acc.totalsLast7.keys.filter {
            PricingTable.lookup($0, table: PricingTable.anthropic) == nil
        })
        let note: String?
        if acc.filesScanned == 0 {
            note = "No recent Claude sessions found."
        } else {
            var details: [String] = []
            if !unpricedLast7.isEmpty {
                details.append("price unavailable for \(unpricedLast7.sorted().joined(separator: ", ")); those turns are excluded from cost totals")
            }
            if acc.unparseableTimestamps > 0 {
                details.append("\(acc.unparseableTimestamps) records had unparseable timestamps (counted into today)")
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
            totalsByModel: acc.totalsToday,
            computedAt: now,
            isApproximate: true,
            note: note,
            unpricedModelsToday: unpricedToday,
            unpricedModelsLast7Days: unpricedLast7,
            dailyUsage: dailyUsage
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
        let requestId: String?
        let message: Message?
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
            struct Usage: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_creation_input_tokens: Int?
                let cache_read_input_tokens: Int?
                let cache_creation: CacheCreation?
                /// "standard" or "fast". Absent on older transcripts, which
                /// predate fast mode and are therefore standard.
                let speed: String?

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
        var dailyTotals: [[String: ModelUsage]] = Array(repeating: [:], count: 7)
        scan(data: data, startOfToday: startOfToday, sevenDaysAgo: sevenDaysAgo,
             totalsToday: &totalsToday, totalsLast7: &totalsLast7,
             dailyTotals: &dailyTotals, unparseableTimestamps: &unparseableTimestamps)
    }

    internal static func scan(
        data: Data,
        startOfToday: Date,
        sevenDaysAgo: Date,
        totalsToday: inout [String: ModelUsage],
        totalsLast7: inout [String: ModelUsage],
        dailyTotals: inout [[String: ModelUsage]],
        unparseableTimestamps: inout Int
    ) {
        var keyed: [String: ScanMemo.KeyedUsage] = [:]
        scanLines(data: data, startOfToday: startOfToday, sevenDaysAgo: sevenDaysAgo,
                  totalsToday: &totalsToday, totalsLast7: &totalsLast7,
                  dailyTotals: &dailyTotals,
                  keyed: &keyed, unparseableTimestamps: &unparseableTimestamps)
        fold(keyed, totalsToday: &totalsToday, totalsLast7: &totalsLast7, dailyTotals: &dailyTotals)
    }

    /// Claude Code writes the same API response to a transcript more than
    /// once (streaming / tool-use splits) and, for resumed or forked
    /// sessions, into more than one file — same `message.id` + `requestId`.
    /// One response is billed once, so keep one record per key: the one with
    /// the largest `output_tokens` (later lines carry the final count), ties
    /// going to the last seen.
    internal static func mergeKeyed(_ record: ScanMemo.KeyedUsage, key: String,
                                    into keyed: inout [String: ScanMemo.KeyedUsage]) {
        if let kept = keyed[key], kept.usage.outputTokens > record.usage.outputTokens { return }
        keyed[key] = record
    }

    private static func fold(_ keyed: [String: ScanMemo.KeyedUsage],
                             totalsToday: inout [String: ModelUsage],
                             totalsLast7: inout [String: ModelUsage],
                             dailyTotals: inout [[String: ModelUsage]]) {
        for record in keyed.values {
            if record.inToday { CostAggregator.add(record.usage, into: &totalsToday, model: record.model) }
            if record.inWeek { CostAggregator.add(record.usage, into: &totalsLast7, model: record.model) }
            if record.dayOffset >= 0 && record.dayOffset <= 6 && dailyTotals.count == 7 {
                CostAggregator.add(record.usage, into: &dailyTotals[6 - Int(record.dayOffset)], model: record.model)
            }
        }
    }

    /// The model's prompt-length threshold, or nil when it has no long tier.
    /// Memoized per scan (nil included, via `updateValue`, so a model with no
    /// tier is not re-looked-up): `PricingTable.lookup` is a linear prefix
    /// scan and `scanLines` calls this for every assistant line.
    private static func longContextThreshold(for model: String,
                                             cache: inout [String: Int?]) -> Int? {
        if let cached = cache[model] { return cached }
        let threshold = PricingTable.lookup(model, table: PricingTable.anthropic)?
            .longContextThresholdTokens
        cache.updateValue(threshold, forKey: model)
        return threshold
    }

    /// Lines carrying both ids go to `keyed` (deduped); lines missing either
    /// id have nothing to dedup on and are added to the totals directly.
    private static func scanLines(
        data: Data,
        startOfToday: Date,
        sevenDaysAgo: Date,
        totalsToday: inout [String: ModelUsage],
        totalsLast7: inout [String: ModelUsage],
        dailyTotals: inout [[String: ModelUsage]],
        keyed: inout [String: ScanMemo.KeyedUsage],
        unparseableTimestamps: inout Int
    ) {
        var longContextThresholds: [String: Int?] = [:]
        let calendar = Calendar.current
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
                  !model.isEmpty,
                  !model.hasPrefix("<"),
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
            // Clamped like the cache-creation counts above: a transcript is a
            // file we don't control, and a negative count would subtract from
            // the total — and, via the fast subsets, from the fast premium.
            let input = max(0, usage.input_tokens ?? 0)
            let output = max(0, usage.output_tokens ?? 0)
            let cacheRead = max(0, usage.cache_read_input_tokens ?? 0)
            let isFast = usage.speed == "fast"
            // Prompt-length pricing (Haiku 5.5): a request whose prompt —
            // input, cache reads AND cache writes — is over the threshold
            // pays the higher rates on every category, output included.
            // Each request is priced on its own, so this is decided per line.
            let isLong: Bool
            if let threshold = longContextThreshold(for: model, cache: &longContextThresholds) {
                let prompt = CostAggregator.saturatingAdd(
                    CostAggregator.saturatingAdd(input, cacheRead), cacheCreateTotal)
                isLong = prompt > threshold
            } else {
                isLong = false
            }
            let modelUsage = ModelUsage(
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreateTokens: cacheCreate5m,
                cacheCreate1hTokens: cacheCreate1h,
                longContextInputTokens: isLong ? input : 0,
                longContextOutputTokens: isLong ? output : 0,
                longContextCacheReadTokens: isLong ? cacheRead : 0,
                longContextCacheCreateTokens: isLong ? cacheCreate5m : 0,
                longContextCacheCreate1hTokens: isLong ? cacheCreate1h : 0,
                fastInputTokens: isFast ? input : 0,
                fastOutputTokens: isFast ? output : 0,
                fastCacheReadTokens: isFast ? cacheRead : 0,
                fastCacheCreateTokens: isFast ? cacheCreate5m : 0,
                fastCacheCreate1hTokens: isFast ? cacheCreate1h : 0
            )

            let ts = parsed.timestamp.flatMap(ISO8601Parsing.parse)
            // Fail-safe: a missing/unparseable timestamp counts into both
            // buckets; the count is surfaced in the note so users spot drift.
            let inToday = ts.map { $0 >= startOfToday } ?? true
            let inWeek = ts.map { $0 >= sevenDaysAgo } ?? true
            let dayOffset: Int8
            if let ts {
                if inWeek {
                    let dayStart = calendar.startOfDay(for: ts)
                    if dayStart > startOfToday {
                        dayOffset = 0
                    } else {
                        let diff = calendar.dateComponents([.day], from: dayStart, to: startOfToday).day ?? -1
                        dayOffset = (diff >= 0 && diff <= 6) ? Int8(diff) : -1
                    }
                } else {
                    dayOffset = -1
                }
            } else {
                dayOffset = 0
            }
            if ts == nil { unparseableTimestamps += 1 }
            if let messageId = msg.id, !messageId.isEmpty,
               let requestId = parsed.requestId, !requestId.isEmpty {
                mergeKeyed(ScanMemo.KeyedUsage(model: model, usage: modelUsage,
                                               inToday: inToday, inWeek: inWeek,
                                               dayOffset: dayOffset),
                           key: messageId + "\u{0}" + requestId, into: &keyed)
            } else {
                if inToday { CostAggregator.add(modelUsage, into: &totalsToday, model: model) }
                if inWeek { CostAggregator.add(modelUsage, into: &totalsLast7, model: model) }
                if dayOffset >= 0 && dayOffset <= 6 && dailyTotals.count == 7 {
                    CostAggregator.add(modelUsage, into: &dailyTotals[6 - Int(dayOffset)], model: model)
                }
            }
        }
    }
}
