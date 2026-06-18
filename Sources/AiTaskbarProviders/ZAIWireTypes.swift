import Foundation
import AiTaskbarCore

/// `GET https://api.z.ai/api/monitor/usage/quota/limit`. The live response:
///
/// ```json
/// { "code": 200, "msg": "Operation successful", "success": true,
///   "data": {
///     "level": "pro",
///     "limits": [
///       { "type": "TIME_LIMIT",   "unit": 5, "number": 1, "usage": 1000,
///         "currentValue": 0, "remaining": 1000, "percentage": 0,
///         "nextResetTime": 1784333321994,
///         "usageDetails": [ { "modelCode": "search-prime", "usage": 0 }, … ] },
///       { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 12,
///         "nextResetTime": 1781759602799 },
///       { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 2,
///         "nextResetTime": 1782346121993 }
///     ] } }
/// ```
///
/// `type` is the discriminator (`TOKENS_LIMIT` for prompt-quota windows,
/// `TIME_LIMIT` for the web-tool quota). `unit` is a **numeric** time-unit code
/// (observed: 3 = hour, 5 = month, 6 = week) and `number` its multiplier — so
/// `unit:3,number:5` is the rolling 5-hour window and `unit:6,number:1` is the
/// weekly cap. `percentage` is utilization (0–100) and `nextResetTime` is epoch
/// **milliseconds**.
public struct ZAIEnvelope: Decodable {
    public let code: Int?
    public let msg: String?
    public let data: ZAIMonitorData
}

public struct ZAIMonitorData: Decodable {
    public let limits: [ZAILimitEntry]
    public let level: String?

    enum CodingKeys: String, CodingKey {
        case limits, level
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limits = try c.decodeIfPresent([ZAILimitEntry].self, forKey: .limits) ?? []
        level = try c.decodeIfPresent(String.self, forKey: .level)
    }
}

public struct ZAILimitEntry: Decodable {
    public let type: String?          // TOKENS_LIMIT | TIME_LIMIT
    public let unit: Int?             // numeric time-unit code (3=hour, 5=month, 6=week)
    public let number: Int?           // unit multiplier (e.g. unit:3 number:5 → 5h)
    public let usage: Double?         // cap (TIME_LIMIT only)
    public let currentValue: Double?  // consumed so far (TIME_LIMIT only)
    public let remaining: Double?
    public let percentage: Double?    // utilization, 0–100
    public let nextResetTime: Double? // epoch milliseconds

    enum CodingKeys: String, CodingKey {
        case type, unit, number, usage, currentValue, remaining, percentage, nextResetTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        unit = c.flexibleDoubleIfPresent(forKey: .unit).map { Int($0) }
        number = c.flexibleDoubleIfPresent(forKey: .number).map { Int($0) }
        usage = c.flexibleDoubleIfPresent(forKey: .usage)
        currentValue = c.flexibleDoubleIfPresent(forKey: .currentValue)
        remaining = c.flexibleDoubleIfPresent(forKey: .remaining)
        percentage = c.flexibleDoubleIfPresent(forKey: .percentage)
        nextResetTime = c.flexibleDoubleIfPresent(forKey: .nextResetTime)
    }
}

extension ZAILimitEntry {
    /// Reset instant. The field is epoch **milliseconds**, but we tolerate a
    /// seconds-encoded value too (anything below ~year 33658 in seconds).
    var resetDate: Date? {
        guard let t = nextResetTime else { return nil }
        let seconds = t > 1_000_000_000_000 ? t / 1000 : t
        return Date(timeIntervalSince1970: seconds)
    }

    /// "used / cap" detail line — only the `TIME_LIMIT` (web-tool) entry carries
    /// `currentValue` + `usage`; token windows report `percentage` only.
    var detailString: String? {
        guard let cap = usage, cap > 0, let used = currentValue else { return nil }
        return String(format: "%.0f / %.0f", used, cap)
    }
}

extension ZAIEnvelope {
    public func toSnapshot(configTier: String?) -> ZAISnapshot {
        let level = data.level ?? configTier
        let planLabel: String? = level.map { "GLM \($0.capitalized)" }

        // Split by `type`: TIME_LIMIT is the web-tool quota (→ mcp slot),
        // everything else (TOKENS_LIMIT) is a prompt-quota window.
        var tokenEntries: [ZAILimitEntry] = []
        var timeEntry: ZAILimitEntry?
        for entry in data.limits {
            let type = (entry.type ?? "").uppercased()
            if type.contains("TIME") {
                if timeEntry == nil { timeEntry = entry }
            } else {
                tokenEntries.append(entry)
            }
        }

        // The soonest-resetting token window is the rolling "session" limit; the
        // later one is the weekly cap. Ordering by reset time keeps the
        // classification correct regardless of the numeric `unit` codes — only
        // the cosmetic hour suffix in `sessionLabel` reads `unit`. The snapshot
        // has just two token slots, so any third+ window is intentionally
        // dropped (the live plan only exposes a 5h + a weekly window).
        tokenEntries.sort {
            ($0.nextResetTime ?? .greatestFiniteMagnitude)
                < ($1.nextResetTime ?? .greatestFiniteMagnitude)
        }

        let session = tokenEntries.first.map {
            makeWindow($0, label: sessionLabel(for: $0))
        }
        let weekly = tokenEntries.dropFirst().first.map {
            makeWindow($0, label: "Weekly")
        }
        let mcp = timeEntry.map { makeWindow($0, label: "Web tools") }

        return ZAISnapshot(
            planLabel: planLabel,
            session: session,
            weekly: weekly,
            mcp: mcp
        )
    }

    private func makeWindow(_ e: ZAILimitEntry, label: String) -> UsageWindow {
        UsageWindow(
            label: label,
            utilizationPercent: e.percentage ?? 0,
            resetsAt: e.resetDate,
            detail: e.detailString
        )
    }

    /// The session window's duration is the meaningful detail (a 5-hour rolling
    /// cap on the GLM coding plan). `unit:3` is the hour code.
    private func sessionLabel(for e: ZAILimitEntry) -> String {
        if e.unit == 3, let n = e.number { return "Session (\(n)h)" }
        return "Session"
    }
}
