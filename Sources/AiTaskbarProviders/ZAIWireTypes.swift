import Foundation
import AiTaskbarCore

/// `GET https://api.z.ai/api/monitor/usage/quota/limit`. Z.AI returns an array
/// of limit entries with mixed shapes — tokens limits + a time limit + an MCP
/// limit. We classify by `unit` field, falling back to positional ordering
/// when units are missing.
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
}

public struct ZAILimitEntry: Decodable {
    public let name: String?
    public let unit: String?        // TOKENS_LIMIT | TIME_LIMIT | MCP_LIMIT
    public let used: Double?
    public let limit: Double?
    public let used_percent: Double?
    public let reset_at: String?
    public let window: String?      // "session" / "weekly" / "monthly"

    enum CodingKeys: String, CodingKey {
        case name, unit, used, limit, used_percent, reset_at, window
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        used = c.flexibleDoubleIfPresent(forKey: .used)
        limit = c.flexibleDoubleIfPresent(forKey: .limit)
        used_percent = c.flexibleDoubleIfPresent(forKey: .used_percent)
        reset_at = try c.decodeIfPresent(String.self, forKey: .reset_at)
        window = try c.decodeIfPresent(String.self, forKey: .window)
    }
}

extension ZAIEnvelope {
    public func toSnapshot(configTier: String?) -> ZAISnapshot {
        let level = data.level ?? configTier
        let planLabel: String? = level.map { "GLM \($0.capitalized)" }

        // Classify entries: first two TOKENS_LIMIT entries become session/weekly,
        // a TIME_LIMIT or MCP-named entry becomes the MCP row.
        var tokenWindows: [UsageWindow] = []
        var mcp: UsageWindow?

        func uw(_ e: ZAILimitEntry, defaultLabel: String) -> UsageWindow {
            let percent = e.used_percent
                ?? (e.limit.map { ($0 > 0 ? (e.used ?? 0) / $0 * 100 : 0) })
                ?? 0
            let label = e.name ?? e.window?.capitalized ?? defaultLabel
            var detail: String?
            if let used = e.used, let limit = e.limit, limit > 0 {
                detail = String(format: "%.0f / %.0f", used, limit)
            }
            return UsageWindow(
                label: label,
                utilizationPercent: percent,
                resetsAt: e.reset_at.flatMap(parseISO8601),
                detail: detail
            )
        }

        for entry in data.limits {
            let unit = (entry.unit ?? "").uppercased()
            if unit.contains("MCP") || (entry.name?.lowercased().contains("mcp") == true) {
                mcp = uw(entry, defaultLabel: "MCP")
            } else if unit.contains("TIME") {
                if mcp == nil { mcp = uw(entry, defaultLabel: "MCP") }
            } else {
                tokenWindows.append(uw(entry, defaultLabel: tokenWindows.isEmpty ? "Session" : "Weekly"))
            }
        }
        return ZAISnapshot(
            planLabel: planLabel,
            session: tokenWindows.first,
            weekly:  tokenWindows.dropFirst().first,
            mcp: mcp
        )
    }
}
