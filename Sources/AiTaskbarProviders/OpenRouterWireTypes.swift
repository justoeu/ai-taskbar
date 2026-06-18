import Foundation
import AiTaskbarCore

/// `GET https://openrouter.ai/api/v1/credits` — documented.
public struct OpenRouterCreditsResponse: Codable, Sendable {
    public let data: CreditsData
    public struct CreditsData: Codable, Sendable {
        public let total_credits: Double?
        public let total_usage: Double?

        enum CodingKeys: String, CodingKey {
            case total_credits, total_usage
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total_credits = c.flexibleDoubleIfPresent(forKey: .total_credits)
            total_usage = c.flexibleDoubleIfPresent(forKey: .total_usage)
        }
    }
}

/// `GET https://openrouter.ai/api/v1/key` — documented.
public struct OpenRouterKeyResponse: Codable, Sendable {
    public let data: KeyData
    public struct KeyData: Codable, Sendable {
        public let label: String?
        public let usage: Double?
        public let limit: Double?
        public let is_free_tier: Bool?
        public let rate_limit: RateLimit?

        public struct RateLimit: Codable, Sendable {
            public let requests: Double?
            public let interval: String?
        }

        enum CodingKeys: String, CodingKey {
            case label, usage, limit, is_free_tier, rate_limit
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            usage = c.flexibleDoubleIfPresent(forKey: .usage)
            limit = c.flexibleDoubleIfPresent(forKey: .limit)
            is_free_tier = try c.decodeIfPresent(Bool.self, forKey: .is_free_tier)
            rate_limit = try c.decodeIfPresent(RateLimit.self, forKey: .rate_limit)
        }
    }
}

/// Payload shape we persist to the disk cache — both upstream responses
/// nested as proper Codable structs (instead of JSON-round-tripping through
/// `JSONSerialization` and `[String: Any]` like the old implementation did).
/// Also carries the snapshot conversion (previously a parallel
/// `OpenRouterCombined` struct with identical fields and the only `toSnapshot`
/// impl — collapsed here so there's a single source of truth).
public struct OpenRouterCachedPayload: Codable, Sendable {
    public let credits: OpenRouterCreditsResponse
    public let key: OpenRouterKeyResponse
    public init(credits: OpenRouterCreditsResponse, key: OpenRouterKeyResponse) {
        self.credits = credits
        self.key = key
    }

    public func toSnapshot() -> OpenRouterSnapshot {
        let total = credits.data.total_credits
        let used  = credits.data.total_usage ?? 0
        let pctOfBudget: Double
        let detail: String
        if let total, total > 0 {
            pctOfBudget = min(used / total * 100, 100)
            detail = String(format: "$%.2f used / $%.2f total", used, total)
        } else {
            // No budget cap reported by the API (free tier or unmetered).
            pctOfBudget = 0
            detail = total == nil
                ? "balance unknown"
                : String(format: "$%.2f used", used)
        }

        let balanceWindow = UsageWindow(
            label: "Balance",
            utilizationPercent: pctOfBudget,
            resetsAt: nil,
            detail: detail
        )

        var monthly: UsageWindow?
        if let limit = key.data.limit, limit > 0, let used = key.data.usage {
            monthly = UsageWindow(
                label: "Key limit",
                utilizationPercent: min(used / limit * 100, 100),
                detail: String(format: "$%.2f / $%.2f", used, limit)
            )
        }
        let planLabel: String?
        if key.data.is_free_tier == true {
            planLabel = "OpenRouter Free Tier"
        } else if let l = key.data.label {
            planLabel = "OpenRouter: \(l)"
        } else {
            planLabel = "OpenRouter"
        }
        return OpenRouterSnapshot(
            planLabel: planLabel,
            balance: balanceWindow,
            daily: nil,
            weekly: nil,
            monthly: monthly
        )
    }
}
