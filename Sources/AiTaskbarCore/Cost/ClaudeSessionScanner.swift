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
    public static func estimate(now: Date = .init(),
                                projectsDir: URL? = nil) -> CostEstimate {
        let projects: URL = projectsDir ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let walker = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return CostEstimate(usdToday: 0, usdLast7Days: 0,
                                isApproximate: true,
                                note: "No ~/.claude/projects directory.")
        }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let sevenDaysAgo = startOfToday.addingTimeInterval(-7 * 86_400)

        var totalsToday: [String: ModelUsage] = [:]
        var totalsLast7: [String: ModelUsage] = [:]
        var filesScanned = 0
        var unparseableTimestamps = 0

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
                 unparseableTimestamps: &unparseableTimestamps)
        }

        let (usdToday, breakdownToday) = price(totals: totalsToday, table: PricingTable.anthropic)
        let (usdWeek, breakdownLast7) = price(totals: totalsLast7, table: PricingTable.anthropic)
        let note: String?
        if filesScanned == 0 {
            note = "No recent Claude sessions found."
        } else if unparseableTimestamps > 0 {
            note = "Approximate — \(unparseableTimestamps) records had unparseable timestamps " +
                   "(counted into today). Subscription users pay flat fee."
        } else {
            note = "Approximate — based on pricing table; subscription users pay flat fee."
        }
        return CostEstimate(
            usdToday: usdToday,
            usdLast7Days: usdWeek,
            modelBreakdownToday: breakdownToday,
            modelBreakdownLast7Days: breakdownLast7,
            totalsByModel: totalsToday,
            computedAt: now,
            isApproximate: true,
            note: note
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
            }
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ s: String) -> Date? {
        // Prefer the fractional-seconds variant since Claude session logs
        // include them by default.
        iso.date(from: s) ?? isoNoFrac.date(from: s)
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

            // Pass the slice as Data to JSONDecoder.
            let parsed: AssistantLine
            do {
                parsed = try SharedCoders.decoder.decode(AssistantLine.self, from: Data(line))
            } catch {
                continue
            }
            guard let msg = parsed.message,
                  let model = msg.model,
                  let usage = msg.usage
            else { continue }

            let modelUsage = ModelUsage(
                inputTokens: usage.input_tokens ?? 0,
                outputTokens: usage.output_tokens ?? 0,
                cacheReadTokens: usage.cache_read_input_tokens ?? 0,
                cacheCreateTokens: usage.cache_creation_input_tokens ?? 0
            )

            let ts = parsed.timestamp.flatMap(parseTimestamp)
            if let ts {
                if ts >= startOfToday { add(modelUsage, into: &totalsToday, model: model) }
                if ts >= sevenDaysAgo { add(modelUsage, into: &totalsLast7, model: model) }
            } else {
                // Fail-safe: count missing-timestamp records into today.
                // We surface the count in the note so users can spot drift.
                add(modelUsage, into: &totalsToday, model: model)
                add(modelUsage, into: &totalsLast7, model: model)
                unparseableTimestamps += 1
            }
        }
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
