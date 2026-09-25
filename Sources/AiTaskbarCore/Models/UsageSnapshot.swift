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
            let agyWindows = [s.fiveHour, s.weekly, s.thirdParty5Hour, s.thirdPartyWeekly].compactMap { $0 }
            if !agyWindows.isEmpty {
                return agyWindows
            }
            return [s.status].compactMap { $0 }
        case .deepseek(let s):
            return [s.balance].compactMap { $0 }
        case .xai(let s):
            return [s.weekly, s.balance, s.monthly].compactMap { $0 }
        }
    }

    /// Worst-case utilization across the snapshot's windows, used by the
    /// menu-bar icon tint.
    public var maxUtilization: Double {
        windows.map(\.utilizationPercent).max() ?? 0
    }

    /// Weekly and current utilization percentages for menu-bar dual display.
    /// `weekly`: 7-day quota utilization, if tracked by the vendor.
    /// `current`: session / 5h / daily / balance utilization.
    public var menuBarDisplayPercentages: (weekly: Double?, current: Double) {
        switch self {
        case .anthropic(let s):
            return (s.weekly?.utilizationPercent, s.session?.utilizationPercent ?? maxUtilization)
        case .openai(let s):
            // OpenAI primary = session (5h), secondary = weekly (7d)
            return (s.secondary?.utilizationPercent, s.primary?.utilizationPercent ?? maxUtilization)
        case .gemini(let s):
            return (s.weekly?.utilizationPercent, s.fiveHour?.utilizationPercent ?? maxUtilization)
        case .zai(let s):
            return (s.weekly?.utilizationPercent, s.session?.utilizationPercent ?? maxUtilization)
        case .openrouter(let s):
            return (s.weekly?.utilizationPercent, s.daily?.utilizationPercent ?? maxUtilization)
        case .xai(let s):
            return (nil, s.weekly?.utilizationPercent ?? maxUtilization)
        case .kimi, .deepseek:
            return (nil, maxUtilization)
        }
    }

    /// Quota windows tracked for menu-bar dual display and reset countdowns.
    /// `dailyOrSession`: session / 5h / daily window, if tracked by the vendor.
    /// `weekly`: 7-day quota window, if tracked by the vendor.
    public var menuBarResetWindows: (dailyOrSession: UsageWindow?, weekly: UsageWindow?) {
        switch self {
        case .anthropic(let s):
            return (s.session, s.weekly)
        case .openai(let s):
            return (s.primary, s.secondary)
        case .gemini(let s):
            return (s.fiveHour, s.weekly)
        case .zai(let s):
            return (s.session, s.weekly)
        case .openrouter(let s):
            return (s.daily, s.weekly)
        case .xai(let s):
            return (nil, s.weekly)
        case .kimi, .deepseek:
            return (nil, nil)
        }
    }

    /// Lifetime accumulated usage in USD if reported by the vendor (e.g. OpenRouter).
    public var lifetimeCostUSD: Double? {
        switch self {
        case .openrouter(let s):
            return s.totalUsageUSD
        default:
            return nil
        }
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

/// Approximate messages a credit balance still funds. Codex reports a range,
/// never a single number, so both ends are kept instead of collapsing them.
public struct CreditMessageRange: Sendable, Equatable, Codable {
    public let low: Int
    public let high: Int

    public init(low: Int, high: Int) {
        self.low = min(low, high)
        self.high = max(low, high)
    }

    /// Builds from the wire's two-element array; nil for any other shape.
    public init?(wire: [Int]?) {
        guard let wire, wire.count >= 2 else { return nil }
        self.init(low: wire[0], high: wire[1])
    }

    /// Routes decoding through the normalizing initializer. The synthesized
    /// one writes the stored properties directly, so a persisted `low > high`
    /// would survive into a range no in-code construction can produce, and
    /// render as "≈ 9–2 messages".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(low: try c.decode(Int.self, forKey: .low),
                  high: try c.decode(Int.self, forKey: .high))
    }
}

/// Codex credits.
///
/// **These are a quantity, not money.** The wire sends
/// `"balance": "4890.3162520000"` — a bare decimal string with no currency
/// symbol and ten decimal places. An earlier version parsed it with a
/// `parseDollar` helper, stored it as `creditsUSD` and rendered it as
/// `"Credits: $%.2f"`, inventing a `$` the API never sent. Nothing in this
/// type is currency and nothing formats it as currency.
public struct OpenAICreditsInfo: Sendable, Equatable, Codable {
    /// Remaining credits. Optional because an unmetered account can omit the
    /// number entirely — and that is precisely the account the `unlimited`
    /// flag and the message ranges describe, so a missing balance must not
    /// discard the whole credits block.
    public let balance: Double?
    /// Highest balance observed so far — the progress bar's denominator,
    /// supplied by `CreditBaselineStore` because the API reports no granted
    /// total. nil when no baseline is known yet.
    public let peakBalance: Double?
    /// Messages the balance still funds in the local Codex CLI.
    public let localMessages: CreditMessageRange?
    /// Messages the balance still funds for cloud tasks. Distinct from
    /// `localMessages`: both are reported and they mean different things, so
    /// neither is allowed to stand in for the other.
    public let cloudMessages: CreditMessageRange?
    public let hasCredits: Bool
    /// A promotional grant was present in this payload. Presence only — the
    /// object's shape is unverified. Used to notice when such a grant ends,
    /// which drops the balance without any of it having been spent.
    public let hasPromo: Bool
    /// Credits are unmetered — a consumption bar would be meaningless.
    public let isUnlimited: Bool
    public let overageLimitReached: Bool
    /// True when the plan window is exhausted and credits are the only reason
    /// requests still go through. Drives the "spending credits" notice.
    public let isFundingRequests: Bool
    /// True only when the plan window is ALSO spent, so nothing can carry a
    /// request any more. Hitting the overage ceiling while the plan still has
    /// room blocks nothing, and claiming otherwise in red is worse than
    /// staying quiet.
    public let requestsBlocked: Bool

    /// Credits ran out. Worth saying out loud: otherwise the bar just pins at
    /// a red 100% with no explanation, which is the failure this change set
    /// out to remove.
    public var isExhausted: Bool { !isUnlimited && (balance ?? 0) <= 0 }

    /// False when the account has no credits enabled and none left — there is
    /// nothing worth a card row. Keeps a zero balance from rendering as a
    /// meaningless "Credits: 0" on plans that never had any.
    public var isWorthShowing: Bool { hasCredits || (balance ?? 0) > 0 }

    /// Share of the observed baseline already spent, 0...100.
    ///
    /// nil until the baseline says something the balance does not. On the very
    /// first sighting the peak IS the balance, and drawing a green 0% bar there
    /// would tell a user who had already burned 90% of their credits that they
    /// had spent nothing. The bar appears once real consumption has been
    /// observed — the first moment the denominator carries information.
    public var consumedPercent: Double? {
        guard !isUnlimited, let balance, let peakBalance, peakBalance > balance else { return nil }
        return CreditBaselineMath.consumedPercent(peak: peakBalance, balance: balance)
    }

    public init(balance: Double?,
                peakBalance: Double? = nil,
                localMessages: CreditMessageRange? = nil,
                cloudMessages: CreditMessageRange? = nil,
                hasCredits: Bool = false,
                hasPromo: Bool = false,
                isUnlimited: Bool = false,
                overageLimitReached: Bool = false,
                isFundingRequests: Bool = false,
                requestsBlocked: Bool = false) {
        self.balance = balance
        self.peakBalance = peakBalance
        self.localMessages = localMessages
        self.cloudMessages = cloudMessages
        self.hasCredits = hasCredits
        self.hasPromo = hasPromo
        self.isUnlimited = isUnlimited
        self.overageLimitReached = overageLimitReached
        self.isFundingRequests = isFundingRequests
        self.requestsBlocked = requestsBlocked
    }

    /// Returns a copy carrying the denominator resolved by the provider.
    public func withPeakBalance(_ peak: Double?) -> OpenAICreditsInfo {
        OpenAICreditsInfo(balance: balance,
                          peakBalance: peak,
                          localMessages: localMessages,
                          cloudMessages: cloudMessages,
                          hasCredits: hasCredits,
                          hasPromo: hasPromo,
                          isUnlimited: isUnlimited,
                          overageLimitReached: overageLimitReached,
                          isFundingRequests: isFundingRequests,
                          requestsBlocked: requestsBlocked)
    }
}

public struct OpenAISnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    /// Paid usage credits. Deliberately NOT folded into `VendorSnapshot.windows`:
    /// the menu-bar percentage tracks plan windows that reset on a clock, and
    /// credits drain on a different axis with a locally-derived denominator.
    /// Mixing them would make the menu bar read 80% because of credits while
    /// the plan sits at 10%.
    public let credits: OpenAICreditsInfo?
    /// Earned resets, not paid usage credits. nil means availability is unknown.
    public let availableResetCount: Int?

    public var canOfferRateLimitReset: Bool {
        guard let count = availableResetCount, count > 0 else { return false }
        return [primary, secondary].compactMap { $0 }.contains {
            $0.utilizationPercent.isFinite && $0.utilizationPercent > 90
        }
    }

    public init(planLabel: String? = nil,
                primary: UsageWindow? = nil,
                secondary: UsageWindow? = nil,
                credits: OpenAICreditsInfo? = nil,
                availableResetCount: Int? = nil) {
        self.planLabel = planLabel
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.availableResetCount = availableResetCount
    }

    /// Returns a copy whose credits carry the resolved baseline.
    public func withCreditsPeak(_ peak: Double?) -> OpenAISnapshot {
        guard let credits else { return self }
        return OpenAISnapshot(planLabel: planLabel,
                              primary: primary,
                              secondary: secondary,
                              credits: credits.withPeakBalance(peak),
                              availableResetCount: availableResetCount)
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

/// Google Gemini usage snapshot.
///
/// Quota and usage metrics can be monitored in two ways:
/// 1. Via Antigravity (`agy`), which tracks dynamic 5-hour and weekly quota windows
///    for Gemini Models and third-party models (Claude/GPT).
/// 2. Via Google AI Studio API key heartbeat (`GET /models`), showing model availability.
///
/// Note: To monitor actual usage and quotas, Antigravity must be installed and authenticated.
public struct GeminiSnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?
    /// Single status row — used as fallback or connectivity check.
    public let status: UsageWindow?
    /// Number of models the API key can list (Google AI Studio fallback).
    public let modelCount: Int?
    /// 5-hour quota window from Antigravity.
    public let fiveHour: UsageWindow?
    /// Weekly quota window from Antigravity.
    public let weekly: UsageWindow?
    /// 3rd-party models (Claude/GPT) 5-hour quota window from Antigravity.
    public let thirdParty5Hour: UsageWindow?
    /// 3rd-party models (Claude/GPT) weekly quota window from Antigravity.
    public let thirdPartyWeekly: UsageWindow?
    /// Mandatory disclaimer explaining that Antigravity is required for quota monitoring.
    public let disclaimer: String?
    /// True when backed by active, authenticated Antigravity data.
    public let isAntigravityActive: Bool

    public init(planLabel: String? = nil,
                status: UsageWindow? = nil,
                modelCount: Int? = nil,
                fiveHour: UsageWindow? = nil,
                weekly: UsageWindow? = nil,
                thirdParty5Hour: UsageWindow? = nil,
                thirdPartyWeekly: UsageWindow? = nil,
                disclaimer: String? = nil,
                isAntigravityActive: Bool = false) {
        self.planLabel = planLabel
        self.status = status
        self.modelCount = modelCount
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.thirdParty5Hour = thirdParty5Hour
        self.thirdPartyWeekly = thirdPartyWeekly
        self.disclaimer = disclaimer
        self.isAntigravityActive = isAntigravityActive
    }
}

public struct OpenRouterSnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?
    public let balance: UsageWindow?
    public let daily: UsageWindow?
    public let weekly: UsageWindow?
    public let monthly: UsageWindow?
    public let topModels: [ModelShare]?
    public let totalUsageUSD: Double?

    public init(planLabel: String? = nil,
                balance: UsageWindow? = nil,
                daily: UsageWindow? = nil,
                weekly: UsageWindow? = nil,
                monthly: UsageWindow? = nil,
                topModels: [ModelShare]? = nil,
                totalUsageUSD: Double? = nil) {
        self.planLabel = planLabel
        self.balance = balance
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
        self.topModels = topModels
        self.totalUsageUSD = totalUsageUSD
    }
}

/// xAI Management API and Grok CLI billing snapshot.
/// Surfaces:
/// - Grok weekly quota usage % and reset countdown (when using Grok CLI)
/// - prepaid credit remaining (balance bar at 0% util, detail = $ available)
/// - current billing-cycle spend vs soft spending limit (monthly % bar when limit > 0)
public struct XAISnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?
    public let weekly: UsageWindow?
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
    /// Mandatory disclaimer explaining that Grok CLI is required for quota monitoring.
    public let disclaimer: String?

    public init(planLabel: String? = nil,
                weekly: UsageWindow? = nil,
                balance: UsageWindow? = nil,
                monthly: UsageWindow? = nil,
                prepaidUSD: Double? = nil,
                spentUSD: Double? = nil,
                spendingLimitUSD: Double? = nil,
                prepaidUsedUSD: Double? = nil,
                billingCycleLabel: String? = nil,
                disclaimer: String? = nil) {
        self.planLabel = planLabel
        self.weekly = weekly
        self.balance = balance
        self.monthly = monthly
        self.prepaidUSD = prepaidUSD
        self.spentUSD = spentUSD
        self.spendingLimitUSD = spendingLimitUSD
        self.prepaidUsedUSD = prepaidUsedUSD
        self.billingCycleLabel = billingCycleLabel
        self.disclaimer = disclaimer
    }

    enum CodingKeys: String, CodingKey {
        case planLabel, weekly, balance, monthly,
             prepaidUSD, spentUSD, spendingLimitUSD,
             prepaidUsedUSD, billingCycleLabel,
             disclaimer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planLabel = try c.decodeIfPresent(String.self, forKey: .planLabel)
        weekly = try c.decodeIfPresent(UsageWindow.self, forKey: .weekly)
        balance = try c.decodeIfPresent(UsageWindow.self, forKey: .balance)
        monthly = try c.decodeIfPresent(UsageWindow.self, forKey: .monthly)
        prepaidUSD = try c.decodeIfPresent(Double.self, forKey: .prepaidUSD)
        spentUSD = try c.decodeIfPresent(Double.self, forKey: .spentUSD)
        spendingLimitUSD = try c.decodeIfPresent(Double.self, forKey: .spendingLimitUSD)
        prepaidUsedUSD = try c.decodeIfPresent(Double.self, forKey: .prepaidUsedUSD)
        billingCycleLabel = try c.decodeIfPresent(String.self, forKey: .billingCycleLabel)
        disclaimer = try c.decodeIfPresent(String.self, forKey: .disclaimer)
    }
}
