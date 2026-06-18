import Foundation
import AiTaskbarCore

/// Wire shapes for `GET https://api.anthropic.com/api/oauth/usage`. Fields are
/// kept Optional because the endpoint is undocumented and Anthropic has been
/// observed to add/remove fields without notice.
public struct AnthropicUsageResponse: Decodable {
    public let five_hour: AnthropicWindow?
    public let seven_day: AnthropicWindow?
    public let seven_day_opus: AnthropicWindow?
    public let extra_usage: AnthropicExtraUsage?

    enum CodingKeys: String, CodingKey {
        case five_hour, seven_day, seven_day_opus, extra_usage
    }
}

public struct AnthropicWindow: Decodable {
    public let utilization: Double?       // 0...100 (sometimes >100)
    public let resets_at: String?         // ISO-8601
    public let used: Double?
    public let limit: Double?

    enum CodingKeys: String, CodingKey {
        case utilization, resets_at, used, limit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = c.flexibleDoubleIfPresent(forKey: .utilization)
        resets_at = try c.decodeIfPresent(String.self, forKey: .resets_at)
        used = c.flexibleDoubleIfPresent(forKey: .used)
        limit = c.flexibleDoubleIfPresent(forKey: .limit)
    }
}

public struct AnthropicExtraUsage: Decodable {
    public let enabled: Bool?
    public let usage_dollars: Double?
    public let limit_dollars: Double?

    enum CodingKeys: String, CodingKey {
        case enabled, usage_dollars, limit_dollars
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        usage_dollars = c.flexibleDoubleIfPresent(forKey: .usage_dollars)
        limit_dollars = c.flexibleDoubleIfPresent(forKey: .limit_dollars)
    }
}

extension AnthropicUsageResponse {
    public func toSnapshot(planLabel: String?) -> AnthropicSnapshot {
        func window(_ raw: AnthropicWindow?, label: String) -> UsageWindow? {
            guard let raw, let percent = raw.utilization else { return nil }
            var detail: String?
            if let used = raw.used, let limit = raw.limit, limit > 0 {
                detail = String(format: "%.0f / %.0f", used, limit)
            }
            return UsageWindow(
                label: label,
                utilizationPercent: percent,
                resetsAt: raw.resets_at.flatMap(ISO8601Parsing.parse),
                detail: detail
            )
        }
        var extra: Double?
        if let ex = extra_usage, ex.enabled == true {
            extra = ex.usage_dollars
        }
        return AnthropicSnapshot(
            planLabel: planLabel,
            session: window(five_hour, label: "Session (5h)"),
            weekly:  window(seven_day, label: "Weekly (7d)"),
            opus:    window(seven_day_opus, label: "Opus (7d)"),
            extraUsageUSD: extra
        )
    }
}
