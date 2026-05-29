import Foundation

/// Discriminated union — each vendor has different shape (different number of
/// windows, different units). The UI switches on this enum.
public enum VendorSnapshot: Sendable, Equatable, Codable {
    case anthropic(AnthropicSnapshot)
    case openai(OpenAISnapshot)
    case zai(ZAISnapshot)
    case openrouter(OpenRouterSnapshot)
    case kimi(KimiSnapshot)
    case gemini(GeminiSnapshot)

    public var vendorId: VendorId {
        switch self {
        case .anthropic:  return .anthropic
        case .openai:     return .openai
        case .zai:        return .zai
        case .openrouter: return .openrouter
        case .kimi:       return .kimi
        case .gemini:     return .gemini
        }
    }

    public var planLabel: String? {
        switch self {
        case .anthropic(let s):  return s.planLabel
        case .openai(let s):     return s.planLabel
        case .zai(let s):        return s.planLabel
        case .openrouter(let s): return s.planLabel
        case .kimi(let s):       return s.planLabel
        case .gemini(let s):     return s.planLabel
        }
    }

    public var windows: [UsageWindow] {
        switch self {
        case .anthropic(let s):
            return [s.session, s.weekly, s.opus].compactMap { $0 }
        case .openai(let s):
            return [s.primary, s.secondary].compactMap { $0 }
        case .zai(let s):
            return [s.session, s.weekly, s.mcp].compactMap { $0 }
        case .openrouter(let s):
            return [s.balance, s.daily, s.weekly, s.monthly].compactMap { $0 }
        case .kimi(let s):
            return [s.balance].compactMap { $0 }
        case .gemini(let s):
            return [s.status].compactMap { $0 }
        }
    }

    /// Worst-case utilization across the snapshot's windows, used by the
    /// menu-bar icon tint.
    public var maxUtilization: Double {
        windows.map(\.utilizationPercent).max() ?? 0
    }
}

// MARK: - Per-vendor snapshots

public struct AnthropicSnapshot: Sendable, Equatable, Codable {
    public var planLabel: String?
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    /// Opus-specific 7-day quota window (wire field: `seven_day_opus`).
    public var opus: UsageWindow?
    /// Extra usage in dollars, only meaningful when a primary window hit 100%.
    public var extraUsageUSD: Double?

    public init(planLabel: String? = nil,
                session: UsageWindow? = nil,
                weekly: UsageWindow? = nil,
                opus: UsageWindow? = nil,
                extraUsageUSD: Double? = nil) {
        self.planLabel = planLabel
        self.session = session
        self.weekly = weekly
        self.opus = opus
        self.extraUsageUSD = extraUsageUSD
    }
}

public struct OpenAISnapshot: Sendable, Equatable, Codable {
    public var planLabel: String?
    public var primary: UsageWindow?
    public var secondary: UsageWindow?
    public var creditsUSD: Double?
    public var messageCountRange: String?  // e.g. "5–10 messages" — Codex reports a range

    public init(planLabel: String? = nil,
                primary: UsageWindow? = nil,
                secondary: UsageWindow? = nil,
                creditsUSD: Double? = nil,
                messageCountRange: String? = nil) {
        self.planLabel = planLabel
        self.primary = primary
        self.secondary = secondary
        self.creditsUSD = creditsUSD
        self.messageCountRange = messageCountRange
    }
}

public struct ZAISnapshot: Sendable, Equatable, Codable {
    public var planLabel: String?
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    public var mcp: UsageWindow?

    public init(planLabel: String? = nil,
                session: UsageWindow? = nil,
                weekly: UsageWindow? = nil,
                mcp: UsageWindow? = nil) {
        self.planLabel = planLabel
        self.session = session
        self.weekly = weekly
        self.mcp = mcp
    }
}

public struct KimiSnapshot: Sendable, Equatable, Codable {
    public var planLabel: String?
    public var balance: UsageWindow?
    /// Total available balance in USD (pre-paid credits).
    public var availableUSD: Double?
    /// Voucher (promo) balance USD, if separately reported.
    public var voucherUSD: Double?
    /// Cash (paid) balance USD, if separately reported.
    public var cashUSD: Double?

    public init(planLabel: String? = nil,
                balance: UsageWindow? = nil,
                availableUSD: Double? = nil,
                voucherUSD: Double? = nil,
                cashUSD: Double? = nil) {
        self.planLabel = planLabel
        self.balance = balance
        self.availableUSD = availableUSD
        self.voucherUSD = voucherUSD
        self.cashUSD = cashUSD
    }
}

/// Google Gemini doesn't expose a public quota/billing REST endpoint on the
/// `generativelanguage.googleapis.com` host. We instead use the `models` list
/// as an authenticated heartbeat: it validates the API key and reports how
/// many models the key can see. The status row shows 0% utilization (we have
/// no quota signal) and the model count is surfaced via `detail`.
public struct GeminiSnapshot: Sendable, Equatable, Codable {
    public var planLabel: String?
    /// Single status row — utilization is always 0%, the detail string carries
    /// "N models available". Acts as a connectivity check.
    public var status: UsageWindow?
    /// Number of models the API key can list. Useful as a quick sanity that
    /// the key still has access to the Generative Language API.
    public var modelCount: Int?

    public init(planLabel: String? = nil,
                status: UsageWindow? = nil,
                modelCount: Int? = nil) {
        self.planLabel = planLabel
        self.status = status
        self.modelCount = modelCount
    }
}

public struct OpenRouterSnapshot: Sendable, Equatable, Codable {
    public var planLabel: String?
    public var balance: UsageWindow?
    public var daily: UsageWindow?
    public var weekly: UsageWindow?
    public var monthly: UsageWindow?

    public init(planLabel: String? = nil,
                balance: UsageWindow? = nil,
                daily: UsageWindow? = nil,
                weekly: UsageWindow? = nil,
                monthly: UsageWindow? = nil) {
        self.planLabel = planLabel
        self.balance = balance
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
    }
}
