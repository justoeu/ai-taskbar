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
    public let rate_limit_reset_credits: OpenAIResetCreditsSummary?

    enum CodingKeys: String, CodingKey {
        case user_id, account_id, email, plan_type, rate_limit,
             code_review_rate_limit, credits, rate_limit_reset_credits
    }
}

/// Same snake_case summary exposed by the installed Codex backend wire model.
/// Optional metadata: invalid/missing counts fail closed without hiding usage.
public struct OpenAIResetCreditsSummary: Decodable {
    public let available_count: Int?

    enum CodingKeys: String, CodingKey { case available_count }

    public init(from decoder: Decoder) throws {
        // This optional summary must not invalidate otherwise valid usage if
        // the experimental metadata changes shape. Unknown means no action.
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            available_count = nil
            return
        }
        available_count = try? c.decodeIfPresent(Int.self, forKey: .available_count)
    }
}

public struct OpenAIRateLimit: Decodable {
    public let primary_window: OpenAIWindow?
    public let secondary_window: OpenAIWindow?
    /// False once the plan window is spent — the account keeps working only
    /// if credits cover it. Absent on older payloads.
    public let allowed: Bool?
    public let limit_reached: Bool?
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

/// Codex credit balance.
///
/// **The balance is a quantity, not money.** The real payload carries
/// `"balance": "4890.3162520000"` — a bare decimal string, no currency
/// symbol, ten decimal places. The previous decoder ran it through a
/// `parseDollar` helper and, on the numeric branches, *built* a
/// `"$%.2f"` string, fabricating a currency the API never sent. Parsing stays
/// tolerant of a stray symbol or thousands separator, but this type never
/// adds one.
public struct OpenAICredits: Decodable {
    /// The balance as the wire sent it when it arrived as a string; for the
    /// numeric forms, the number rendered back plainly. Either way it never
    /// carries a currency symbol this app invented. Diagnostics only.
    public let balance_raw: String?
    public let balance_number: Double?
    public let has_credits: Bool?
    public let unlimited: Bool?
    public let overage_limit_reached: Bool?
    public let approx_local_messages: [Int]?
    public let approx_cloud_messages: [Int]?

    enum CodingKeys: String, CodingKey {
        case balance, has_credits, unlimited, overage_limit_reached,
             approx_local_messages, approx_cloud_messages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decodeIfPresent(String.self, forKey: .balance) {
            balance_raw = s
            balance_number = Self.parseDecimal(s)
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .balance) {
            balance_number = d
            balance_raw = String(d)
        } else if let i = try? c.decodeIfPresent(Int64.self, forKey: .balance) {
            balance_number = Double(i)
            balance_raw = String(i)
        } else {
            balance_raw = nil
            balance_number = nil
        }
        has_credits = try c.decodeIfPresent(Bool.self, forKey: .has_credits)
        unlimited = try c.decodeIfPresent(Bool.self, forKey: .unlimited)
        overage_limit_reached = try c.decodeIfPresent(Bool.self, forKey: .overage_limit_reached)
        approx_local_messages = try c.decodeIfPresent([Int].self, forKey: .approx_local_messages)
        approx_cloud_messages = try c.decodeIfPresent([Int].self, forKey: .approx_cloud_messages)
    }

    /// Symbols and separators dropped before parsing. Commas are thousands
    /// separators on this wire (the decimal point is always `.`), so removing
    /// them everywhere — not just at the ends — is safe here.
    private static let strippable = CharacterSet(charactersIn: "$€£¥ \u{00a0},_")

    private static func parseDecimal(_ s: String) -> Double? {
        let kept = s.unicodeScalars.filter { !strippable.contains($0) }
        return Double(String(String.UnicodeScalarView(kept)))
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

        // Structured, not a pre-rendered sentence: the old code built
        // "≈ 5–10 local msgs left" here, in English, inside Providers — which
        // is why a pt-BR card showed an English line. Formatting belongs to
        // the localized view layer. Both ranges are carried: local (Codex CLI)
        // and cloud (cloud tasks) are reported together and mean different
        // things, so neither substitutes for the other.
        let creditsInfo: OpenAICreditsInfo? = credits.flatMap { c -> OpenAICreditsInfo? in
            guard let balance = c.balance_number else { return nil }
            let hasCredits = c.has_credits ?? false
            let overage = c.overage_limit_reached ?? false
            // `allowed == false` / `limit_reached == true` mean the plan
            // window is spent; with credits still available and no overage
            // ceiling hit, every further request is credit-funded.
            let planSpent = rate_limit?.limit_reached == true || rate_limit?.allowed == false
            return OpenAICreditsInfo(
                balance: balance,
                // Denominator is resolved by the provider from the persisted
                // baseline; the wire carries no granted total.
                peakBalance: nil,
                localMessages: CreditMessageRange(wire: c.approx_local_messages),
                cloudMessages: CreditMessageRange(wire: c.approx_cloud_messages),
                hasCredits: hasCredits,
                isUnlimited: c.unlimited ?? false,
                overageLimitReached: overage,
                isFundingRequests: planSpent && hasCredits && !overage
            )
        }

        return OpenAISnapshot(
            planLabel: planLabel ?? plan_type.map { "ChatGPT \($0.capitalized)" },
            primary: window(rate_limit?.primary_window, kind: .primary),
            secondary: window(rate_limit?.secondary_window, kind: .secondary),
            credits: creditsInfo,
            availableResetCount: rate_limit_reset_credits?.available_count
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
