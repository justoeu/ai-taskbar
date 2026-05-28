import Foundation
import AiTaskbarCore

/// `GET https://chatgpt.com/backend-api/wham/usage`. Field names below match
/// the real schema verbatim — confirmed against the official `codex` CLI's
/// Rust source. NEVER auto-convert (snake_case ↔ camelCase): the wire is
/// strictly snake_case here.
public struct OpenAIUsageResponse: Decodable {
    public let user_id: String?
    public let account_id: String?
    public let email: String?
    public let plan_type: String?
    public let rate_limit: OpenAIRateLimit?
    public let code_review_rate_limit: OpenAIRateLimit?
    public let credits: OpenAICredits?

    enum CodingKeys: String, CodingKey {
        case user_id, account_id, email, plan_type, rate_limit,
             code_review_rate_limit, credits
    }
}

public struct OpenAIRateLimit: Decodable {
    public let primary_window: OpenAIWindow?
    public let secondary_window: OpenAIWindow?
}

public struct OpenAIWindow: Decodable {
    public let used_percent: Double?
    public let limit_window_seconds: Double?
    /// Unix seconds.
    public let reset_at: Double?
    public let reset_after_seconds: Double?

    enum CodingKeys: String, CodingKey {
        case used_percent, limit_window_seconds, reset_at, reset_after_seconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        used_percent = c.flexibleDoubleIfPresent(forKey: .used_percent)
        limit_window_seconds = c.flexibleDoubleIfPresent(forKey: .limit_window_seconds)
        reset_at = c.flexibleDoubleIfPresent(forKey: .reset_at)
        reset_after_seconds = c.flexibleDoubleIfPresent(forKey: .reset_after_seconds)
    }
}

public struct OpenAICredits: Decodable {
    /// API returns either a formatted string ("$5.00") or a raw number.
    public let balance_string: String?
    public let balance_number: Double?
    public let has_credits: Bool?
    public let unlimited: Bool?
    public let approx_local_messages: [Int]?
    public let approx_cloud_messages: [Int]?

    enum CodingKeys: String, CodingKey {
        case balance, has_credits, unlimited,
             approx_local_messages, approx_cloud_messages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decodeIfPresent(String.self, forKey: .balance) {
            balance_string = s
            balance_number = Self.parseDollar(s)
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .balance) {
            balance_number = d
            balance_string = String(format: "$%.2f", d)
        } else if let i = try? c.decodeIfPresent(Int64.self, forKey: .balance) {
            balance_number = Double(i)
            balance_string = String(format: "$%d", i)
        } else {
            balance_string = nil
            balance_number = nil
        }
        has_credits = try c.decodeIfPresent(Bool.self, forKey: .has_credits)
        unlimited = try c.decodeIfPresent(Bool.self, forKey: .unlimited)
        approx_local_messages = try c.decodeIfPresent([Int].self, forKey: .approx_local_messages)
        approx_cloud_messages = try c.decodeIfPresent([Int].self, forKey: .approx_cloud_messages)
    }

    private static let dollarStrip = CharacterSet(charactersIn: "$ ,")

    private static func parseDollar(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: dollarStrip))
    }
}

extension OpenAIUsageResponse {
    public func toSnapshot(planLabel: String?, fallbackNow: Date = .init()) -> OpenAISnapshot {
        func window(_ raw: OpenAIWindow?, kind: WindowKind) -> UsageWindow? {
            guard let raw, let percent = raw.used_percent else { return nil }
            let label = kind.label(from: raw.limit_window_seconds)
            let resets: Date? = raw.reset_at.map { Date(timeIntervalSince1970: $0) }
                ?? raw.reset_after_seconds.map { fallbackNow.addingTimeInterval($0) }
            return UsageWindow(label: label,
                               utilizationPercent: percent,
                               resetsAt: resets,
                               detail: nil)
        }

        var msgRange: String?
        if let local = credits?.approx_local_messages, local.count >= 2 {
            msgRange = "≈ \(local[0])–\(local[1]) local msgs left"
        } else if let cloud = credits?.approx_cloud_messages, cloud.count >= 2 {
            msgRange = "≈ \(cloud[0])–\(cloud[1]) cloud msgs left"
        }

        return OpenAISnapshot(
            planLabel: planLabel ?? plan_type.map { "ChatGPT \($0.capitalized)" },
            primary: window(rate_limit?.primary_window, kind: .primary),
            secondary: window(rate_limit?.secondary_window, kind: .secondary),
            creditsUSD: credits?.balance_number,
            messageCountRange: msgRange
        )
    }

    private enum WindowKind {
        case primary, secondary
        func label(from seconds: Double?) -> String {
            switch self {
            case .primary:
                return Self.humanLabel(prefix: "Session", seconds: seconds, defaultSpan: "5h")
            case .secondary:
                return Self.humanLabel(prefix: "Weekly", seconds: seconds, defaultSpan: "7d")
            }
        }
        static func humanLabel(prefix: String, seconds: Double?, defaultSpan: String) -> String {
            guard let s = seconds, s > 0 else { return "\(prefix) (\(defaultSpan))" }
            let hours = s / 3600
            let days = s / 86_400
            if days >= 1 {
                return "\(prefix) (\(Int(days.rounded()))d)"
            } else {
                return "\(prefix) (\(Int(hours.rounded()))h)"
            }
        }
    }
}
