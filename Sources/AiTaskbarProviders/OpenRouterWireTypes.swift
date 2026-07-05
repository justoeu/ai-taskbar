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
        public let usage_daily: Double?
        public let usage_weekly: Double?
        public let usage_monthly: Double?
        public let limit_remaining: Double?
        public let limit_reset: String?

        public struct RateLimit: Codable, Sendable {
            public let requests: Double?
            public let interval: String?
        }

        enum CodingKeys: String, CodingKey {
            case label, usage, limit, is_free_tier, rate_limit
            case usage_daily, usage_weekly, usage_monthly
            case limit_remaining, limit_reset
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            usage = c.flexibleDoubleIfPresent(forKey: .usage)
            limit = c.flexibleDoubleIfPresent(forKey: .limit)
            is_free_tier = try c.decodeIfPresent(Bool.self, forKey: .is_free_tier)
            rate_limit = try c.decodeIfPresent(RateLimit.self, forKey: .rate_limit)
            usage_daily = c.flexibleDoubleIfPresent(forKey: .usage_daily)
            usage_weekly = c.flexibleDoubleIfPresent(forKey: .usage_weekly)
            usage_monthly = c.flexibleDoubleIfPresent(forKey: .usage_monthly)
            limit_remaining = c.flexibleDoubleIfPresent(forKey: .limit_remaining)
            limit_reset = try c.decodeIfPresent(String.self, forKey: .limit_reset)
        }
    }
}

/// `GET https://openrouter.ai/api/v1/activity` — requires management key.
/// Returns per-model usage data for the last 30 days, grouped by model+date.
public struct OpenRouterActivityResponse: Codable, Sendable {
    public let data: [OpenRouterActivityItem]
}

public struct OpenRouterActivityItem: Codable, Sendable {
    public let model: String
    public let usage: Double?
    public let requests: Double?
    public let prompt_tokens: Double?
    public let completion_tokens: Double?
    public let reasoning_tokens: Double?

    enum CodingKeys: String, CodingKey {
        case model, usage, requests
        case prompt_tokens, completion_tokens, reasoning_tokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        usage = c.flexibleDoubleIfPresent(forKey: .usage)
        requests = c.flexibleDoubleIfPresent(forKey: .requests)
        prompt_tokens = c.flexibleDoubleIfPresent(forKey: .prompt_tokens)
        completion_tokens = c.flexibleDoubleIfPresent(forKey: .completion_tokens)
        reasoning_tokens = c.flexibleDoubleIfPresent(forKey: .reasoning_tokens)
    }
}

/// Payload shape we persist to the disk cache — upstream responses nested as
/// proper Codable structs. Also carries the snapshot conversion.
public struct OpenRouterCachedPayload: Codable, Sendable {
    public let credits: OpenRouterCreditsResponse
    public let key: OpenRouterKeyResponse
    public let activity: OpenRouterActivityResponse?

    public init(credits: OpenRouterCreditsResponse,
                key: OpenRouterKeyResponse,
                activity: OpenRouterActivityResponse? = nil) {
        self.credits = credits
        self.key = key
        self.activity = activity
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

        let keyLimit = key.data.limit

        var daily: UsageWindow?
        if let d = key.data.usage_daily, d > 0 {
            daily = periodWindow(label: "Daily", used: d, limit: keyLimit)
        }

        var weekly: UsageWindow?
        if let w = key.data.usage_weekly, w > 0 {
            weekly = periodWindow(label: "Weekly", used: w, limit: keyLimit)
        }

        var monthly: UsageWindow?
        if let m = key.data.usage_monthly, m > 0 {
            monthly = periodWindow(label: "Monthly", used: m, limit: keyLimit)
        } else if let limit = keyLimit, limit > 0, let used = key.data.usage {
            monthly = UsageWindow(
                label: "Monthly",
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

        var topModels: [ModelShare]?
        if let items = activity?.data, !items.isEmpty {
            var totals: [String: Double] = [:]
            for item in items {
                guard let usage = item.usage, usage > 0 else { continue }
                totals[item.model, default: 0] += usage
            }
            let totalUsage = totals.values.reduce(0, +)
            if totalUsage > 0 {
                topModels = totals
                    .map { (model, used) in
                        ModelShare(model: model,
                                   percent: used / totalUsage * 100,
                                   rawUsage: used)
                    }
                    .sorted { $0.rawUsage > $1.rawUsage }
            }
        }

        return OpenRouterSnapshot(
            planLabel: planLabel,
            balance: balanceWindow,
            daily: daily,
            weekly: weekly,
            monthly: monthly,
            topModels: topModels
        )
    }

    private func periodWindow(label: String, used: Double, limit: Double?) -> UsageWindow {
        if let limit, limit > 0 {
            return UsageWindow(
                label: label,
                utilizationPercent: min(used / limit * 100, 100),
                detail: String(format: "$%.2f / $%.2f", used, limit)
            )
        } else {
            return UsageWindow(
                label: label,
                utilizationPercent: 0,
                detail: String(format: "$%.2f used", used)
            )
        }
    }
}
