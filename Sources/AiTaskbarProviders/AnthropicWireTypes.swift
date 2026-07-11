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
    /// Newer structured limits array. Model-scoped windows (e.g. "Fable") live
    /// here as `weekly_scoped` entries carrying a `scope.model.display_name` —
    /// the flat `seven_day_*` fields for those models now come back `null`.
    public let limits: [AnthropicLimit]?

    enum CodingKeys: String, CodingKey {
        case five_hour, seven_day, seven_day_opus, extra_usage, limits
    }
}

/// One entry of the `limits` array. Generic on purpose: any entry with a
/// `scope.model.display_name` is a per-model quota, so a newly-launched model
/// surfaces without a code change.
public struct AnthropicLimit: Decodable {
    public let kind: String?          // "session" | "weekly_all" | "weekly_scoped" | …
    public let group: String?         // "session" | "weekly"
    public let percent: Double?       // 0…100 (sometimes >100)
    public let severity: String?      // "normal" | "warning" | "critical"
    public let resets_at: String?     // ISO-8601
    public let is_active: Bool?
    public let scope: AnthropicLimitScope?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, resets_at, is_active, scope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        percent = c.flexibleDoubleIfPresent(forKey: .percent)
        severity = try c.decodeIfPresent(String.self, forKey: .severity)
        resets_at = try c.decodeIfPresent(String.self, forKey: .resets_at)
        is_active = try c.decodeIfPresent(Bool.self, forKey: .is_active)
        scope = try c.decodeIfPresent(AnthropicLimitScope.self, forKey: .scope)
    }
}

public struct AnthropicLimitScope: Decodable {
    public let model: AnthropicLimitModel?
}

public struct AnthropicLimitModel: Decodable {
    public let id: String?
    public let display_name: String?
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

/// Usage credits ("Créditos de uso"). Anthropic renamed these fields: the old
/// `enabled` / `usage_dollars` / `limit_dollars` are gone, replaced by
/// `is_enabled` / `used_credits` / `monthly_limit` plus an explicit currency
/// and minor-unit scale (`used_credits` = 55668, `decimal_places` = 2, currency
/// "BRL" → R$556.68). Amounts are minor units (divide by 10^decimal_places).
public struct AnthropicExtraUsage: Decodable {
    public let is_enabled: Bool?
    public let monthly_limit: Double?
    public let used_credits: Double?
    public let utilization: Double?
    public let currency: String?
    public let decimal_places: Int?

    enum CodingKeys: String, CodingKey {
        case is_enabled, monthly_limit, used_credits, utilization, currency, decimal_places
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        is_enabled = try c.decodeIfPresent(Bool.self, forKey: .is_enabled)
        monthly_limit = c.flexibleDoubleIfPresent(forKey: .monthly_limit)
        used_credits = c.flexibleDoubleIfPresent(forKey: .used_credits)
        utilization = c.flexibleDoubleIfPresent(forKey: .utilization)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        decimal_places = try c.decodeIfPresent(Int.self, forKey: .decimal_places)
    }
}

/// Deterministic, locale-independent money formatting for the credits detail
/// line. Kept locale-free so golden tests stay stable across machines/CI; the
/// view layer can localize later if needed.
enum AnthropicMoneyFormat {
    static func range(usedMinor: Double, limitMinor: Double,
                      currency: String?, decimalPlaces: Int) -> String {
        let sym = symbol(for: currency)
        return "\(sym)\(amount(usedMinor, dp: decimalPlaces)) / \(sym)\(amount(limitMinor, dp: decimalPlaces))"
    }

    static func amount(_ minor: Double, dp: Int) -> String {
        let divisor = pow(10.0, Double(max(0, dp)))
        return String(format: "%.\(max(0, dp))f", minor / divisor)
    }

    static func symbol(for currency: String?) -> String {
        switch currency?.uppercased() {
        case "BRL": return "R$"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case .some(let code) where !code.isEmpty: return "\(code) "
        default: return ""
        }
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
        // Model-scoped weekly windows from the generic `limits` array. Any
        // entry carrying a model display name is a per-model quota (e.g.
        // "Fable"); emit them all so a new model appears without a code change.
        // Skip the plain session / weekly_all entries — those already come
        // through the flat `five_hour` / `seven_day` fields above.
        let scoped: [UsageWindow] = (limits ?? []).compactMap { limit in
            guard let name = limit.scope?.model?.display_name,
                  let percent = limit.percent else { return nil }
            return UsageWindow(
                label: "\(name) (7d)",
                utilizationPercent: percent,
                resetsAt: limit.resets_at.flatMap(ISO8601Parsing.parse),
                detail: nil
            )
        }

        // Usage credits: percent bar + money detail (e.g. "R$556.68 / R$600.00").
        var credits: UsageWindow?
        if let ex = extra_usage, ex.is_enabled == true, let percent = ex.utilization {
            var detail: String?
            if let used = ex.used_credits, let limit = ex.monthly_limit {
                detail = AnthropicMoneyFormat.range(
                    usedMinor: used, limitMinor: limit,
                    currency: ex.currency, decimalPlaces: ex.decimal_places ?? 2)
            }
            credits = UsageWindow(label: "Usage credits",
                                  utilizationPercent: percent,
                                  resetsAt: nil,
                                  detail: detail)
        }

        return AnthropicSnapshot(
            planLabel: planLabel,
            session: window(five_hour, label: "Session (5h)"),
            weekly:  window(seven_day, label: "Weekly (7d)"),
            opus:    window(seven_day_opus, label: "Opus (7d)"),
            scoped:  scoped,
            credits: credits
        )
    }
}
