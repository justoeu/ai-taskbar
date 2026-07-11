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
    case deepseek(DeepSeekSnapshot)
    case xai(XAISnapshot)

    public var vendorId: VendorId {
        switch self {
        case .anthropic:  return .anthropic
        case .openai:     return .openai
        case .zai:        return .zai
        case .openrouter: return .openrouter
        case .kimi:       return .kimi
        case .gemini:     return .gemini
        case .deepseek:   return .deepseek
        case .xai:        return .xai
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
        case .deepseek(let s):   return s.planLabel
        case .xai(let s):        return s.planLabel
        }
    }

    public var windows: [UsageWindow] {
        switch self {
        case .anthropic(let s):
            return [s.session, s.weekly].compactMap { $0 }
                + s.scoped
                + [s.opus, s.credits].compactMap { $0 }
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
        case .deepseek(let s):
            return [s.balance].compactMap { $0 }
        case .xai(let s):
            return [s.balance, s.monthly].compactMap { $0 }
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
    public let planLabel: String?
    public let session: UsageWindow?
    public let weekly: UsageWindow?
    /// Opus-specific 7-day quota window (wire field: `seven_day_opus`).
    public let opus: UsageWindow?
    /// Model-scoped weekly windows parsed generically from the wire `limits`
    /// array (e.g. "Fable (7d)"). Empty when the account has none active.
    public let scoped: [UsageWindow]
    /// Usage-credits window (wire `extra_usage`): `utilizationPercent` from the
    /// credits utilization, `detail` carries the money range ("R$556.68 /
    /// R$600.00"). nil when the account has no credits enabled.
    public let credits: UsageWindow?

    public init(planLabel: String? = nil,
                session: UsageWindow? = nil,
                weekly: UsageWindow? = nil,
                opus: UsageWindow? = nil,
                scoped: [UsageWindow] = [],
                credits: UsageWindow? = nil) {
        self.planLabel = planLabel
        self.session = session
        self.weekly = weekly
        self.opus = opus
        self.scoped = scoped
        self.credits = credits
    }

    enum CodingKeys: String, CodingKey {
        case planLabel, session, weekly, opus, scoped, credits
    }

    // Custom decoder so history persisted before `scoped`/`credits` existed
    // (or the old `extraUsageUSD` shape) still decodes: missing new keys
    // default to empty/nil instead of failing the whole record.
    // NOTE: `encode(to:)` is synthesized from `CodingKeys`. If you add a stored
    // property, update `CodingKeys` AND this decoder in lockstep, or the
    // round-trip silently drops the new field on decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planLabel = try c.decodeIfPresent(String.self, forKey: .planLabel)
        session = try c.decodeIfPresent(UsageWindow.self, forKey: .session)
        weekly = try c.decodeIfPresent(UsageWindow.self, forKey: .weekly)
        opus = try c.decodeIfPresent(UsageWindow.self, forKey: .opus)
        scoped = try c.decodeIfPresent([UsageWindow].self, forKey: .scoped) ?? []
        credits = try c.decodeIfPresent(UsageWindow.self, forKey: .credits)
    }
}

public struct OpenAISnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let creditsUSD: Double?
    public let messageCountRange: String?  // e.g. "5–10 messages" — Codex reports a range

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
    public let planLabel: String?
    public let session: UsageWindow?
    public let weekly: UsageWindow?
    public let mcp: UsageWindow?
    /// Top models consumed in the current window, sorted by usage descending.
    /// Surfaced from the `usageDetails` array Z.AI returns inside the
    /// TIME_LIMIT entry — the only per-model signal the API exposes. Empty /
    /// nil when the array is absent (older accounts, nothing used yet).
    public let topModels: [ModelShare]?

    public init(planLabel: String? = nil,
                session: UsageWindow? = nil,
                weekly: UsageWindow? = nil,
                mcp: UsageWindow? = nil,
                topModels: [ModelShare]? = nil) {
        self.planLabel = planLabel
        self.session = session
        self.weekly = weekly
        self.mcp = mcp
        self.topModels = topModels
    }
}

/// A single model's share of total usage within a window. Reusable across
/// vendors — currently populated by Z.AI's `usageDetails`, but any future
/// vendor that exposes per-model consumption can surface the same shape.
/// `percent` is the share of total usage (0–100, summing to ~100 across the
/// array); `rawUsage` is the vendor-native absolute count (calls, tokens,
/// credits — whatever the wire type carries). Named `ModelShare` (not
/// `ModelUsage`, which is already taken by the local cost aggregator).
public struct ModelShare: Sendable, Equatable, Codable {
    public let model: String
    public let percent: Double
    public let rawUsage: Double

    public init(model: String, percent: Double, rawUsage: Double) {
        self.model = model
        self.percent = percent
        self.rawUsage = rawUsage
    }
}

public struct KimiSnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?
    public let balance: UsageWindow?
    /// Total available balance in USD (pre-paid credits).
    public let availableUSD: Double?
    /// Voucher (promo) balance USD, if separately reported.
    public let voucherUSD: Double?
    /// Cash (paid) balance USD, if separately reported.
    public let cashUSD: Double?

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

/// DeepSeek does not expose a token-usage / quota / cost REST endpoint —
/// the only account-level signal its public API offers is prepaid balance via
/// `GET /user/balance`. This snapshot therefore mirrors `KimiSnapshot`: a flat
/// "Balance" row with 0% utilization (no quota window, no `resetsAt`). A
/// DeepSeek account may carry both a USD and a CNY balance; we surface the USD
/// entry (CNY as fallback) and keep the reported `currency` code so the UI can
/// distinguish them. `isAvailable` reflects the API's sufficiency flag (false
/// → DeepSeek would answer 402 on the next call).
public struct DeepSeekSnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?
    public let balance: UsageWindow?
    /// Total balance of the chosen currency entry (granted + topped-up).
    public let totalBalance: Double?
    /// Promo / free credit (expires), if reported.
    public let grantedBalance: Double?
    /// Paid credit, if reported.
    public let toppedUpBalance: Double?
    /// Currency code of the entry we surfaced — "USD" or "CNY".
    public let currency: String?
    /// DeepSeek's "balance sufficient for API calls" flag.
    public let isAvailable: Bool?

    public init(planLabel: String? = nil,
                balance: UsageWindow? = nil,
                totalBalance: Double? = nil,
                grantedBalance: Double? = nil,
                toppedUpBalance: Double? = nil,
                currency: String? = nil,
                isAvailable: Bool? = nil) {
        self.planLabel = planLabel
        self.balance = balance
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.currency = currency
        self.isAvailable = isAvailable
    }
}

/// Google Gemini doesn't expose a public quota/billing REST endpoint on the
/// `generativelanguage.googleapis.com` host. We instead use the `models` list
/// as an authenticated heartbeat: it validates the API key and reports how
/// many models the key can see. The status row shows 0% utilization (we have
/// no quota signal) and the model count is surfaced via `detail`.
public struct GeminiSnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?
    /// Single status row — utilization is always 0%, the detail string carries
    /// "N models available". Acts as a connectivity check.
    public let status: UsageWindow?
    /// Number of models the API key can list. Useful as a quick sanity that
    /// the key still has access to the Generative Language API.
    public let modelCount: Int?

    public init(planLabel: String? = nil,
                status: UsageWindow? = nil,
                modelCount: Int? = nil) {
        self.planLabel = planLabel
        self.status = status
        self.modelCount = modelCount
    }
}

public struct OpenRouterSnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?
    public let balance: UsageWindow?
    public let daily: UsageWindow?
    public let weekly: UsageWindow?
    public let monthly: UsageWindow?
    public let topModels: [ModelShare]?

    public init(planLabel: String? = nil,
                balance: UsageWindow? = nil,
                daily: UsageWindow? = nil,
                weekly: UsageWindow? = nil,
                monthly: UsageWindow? = nil,
                topModels: [ModelShare]? = nil) {
        self.planLabel = planLabel
        self.balance = balance
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
        self.topModels = topModels
    }
}

/// xAI Management API billing snapshot. Inference API keys cannot read usage —
/// only a **management key** + team ID can. Surfaces:
/// - prepaid credit remaining (balance bar at 0% util, detail = $ available)
/// - current billing-cycle spend vs soft spending limit (monthly % bar when limit > 0)
public struct XAISnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?
    public let balance: UsageWindow?
    public let monthly: UsageWindow?
    /// Prepaid credits remaining in USD (absolute dollars).
    public let prepaidUSD: Double?
    /// Postpaid spend so far this billing cycle, USD.
    public let spentUSD: Double?
    /// Soft spending limit for the cycle, USD (0 = prepaid-only).
    public let spendingLimitUSD: Double?
    /// Prepaid credits consumed this cycle, USD.
    public let prepaidUsedUSD: Double?
    /// Billing cycle label, e.g. "2026-07".
    public let billingCycleLabel: String?

    public init(planLabel: String? = nil,
                balance: UsageWindow? = nil,
                monthly: UsageWindow? = nil,
                prepaidUSD: Double? = nil,
                spentUSD: Double? = nil,
                spendingLimitUSD: Double? = nil,
                prepaidUsedUSD: Double? = nil,
                billingCycleLabel: String? = nil) {
        self.planLabel = planLabel
        self.balance = balance
        self.monthly = monthly
        self.prepaidUSD = prepaidUSD
        self.spentUSD = spentUSD
        self.spendingLimitUSD = spendingLimitUSD
        self.prepaidUsedUSD = prepaidUsedUSD
        self.billingCycleLabel = billingCycleLabel
    }
}
