import Foundation
import AiTaskbarCore

/// Wire types for xAI Management API billing endpoints.
/// Base: `https://management-api.x.ai`
/// Auth: Bearer management key (NOT the inference API key).
///
/// Endpoints used:
/// - `GET /v1/billing/teams/{teamId}/prepaid/balance`
/// - `GET /v1/billing/teams/{teamId}/postpaid/invoice/preview`
///
/// Money fields are USD cents stored as JSON strings (and sometimes nested
/// under `{ "val": "..." }`). Prepaid remaining is signed: purchases land as
/// negative cents; we take the absolute value for display.

// MARK: - USD cents helpers

/// Nested `{ "val": "<cents as string or number>" }` used throughout xAI billing.
public struct XAICentsValue: Decodable, Encodable, Sendable, Equatable {
    public let val: Double?

    public init(val: Double?) { self.val = val }

    enum CodingKeys: String, CodingKey { case val }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        val = Self.numeric(c, .val)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(val, forKey: .val)
    }

    private static func numeric(_ c: KeyedDecodingContainer<CodingKeys>,
                                _ key: CodingKeys) -> Double? {
        if let d = c.flexibleDoubleIfPresent(forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key), let d = Double(s) { return d }
        return nil
    }

    /// Convert cents → absolute USD dollars.
    public var usd: Double? {
        guard let v = val else { return nil }
        return abs(v) / 100.0
    }
}

// MARK: - Prepaid balance

public struct XAIPrepaidBalanceResponse: Decodable, Encodable, Sendable, Equatable {
    public let total: XAICentsValue?

    enum CodingKeys: String, CodingKey { case total }

    public init(total: XAICentsValue?) { self.total = total }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeIfPresent(XAICentsValue.self, forKey: .total)
    }
}

// MARK: - Invoice preview (current cycle spend)

public struct XAIInvoicePreviewResponse: Decodable, Encodable, Sendable, Equatable {
    public let coreInvoice: XAICoreInvoice?
    public let effectiveSpendingLimit: Double?
    public let defaultCredits: Double?
    public let billingCycle: XAIBillingCycle?

    enum CodingKeys: String, CodingKey {
        case coreInvoice = "coreInvoice"
        case effectiveSpendingLimit = "effectiveSpendingLimit"
        case defaultCredits = "defaultCredits"
        case billingCycle = "billingCycle"
    }

    public init(coreInvoice: XAICoreInvoice?,
                effectiveSpendingLimit: Double?,
                defaultCredits: Double?,
                billingCycle: XAIBillingCycle?) {
        self.coreInvoice = coreInvoice
        self.effectiveSpendingLimit = effectiveSpendingLimit
        self.defaultCredits = defaultCredits
        self.billingCycle = billingCycle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coreInvoice = try c.decodeIfPresent(XAICoreInvoice.self, forKey: .coreInvoice)
        effectiveSpendingLimit = Self.numeric(c, .effectiveSpendingLimit)
        defaultCredits = Self.numeric(c, .defaultCredits)
        billingCycle = try c.decodeIfPresent(XAIBillingCycle.self, forKey: .billingCycle)
    }

    private static func numeric(_ c: KeyedDecodingContainer<CodingKeys>,
                                _ key: CodingKeys) -> Double? {
        if let d = c.flexibleDoubleIfPresent(forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key), let d = Double(s) { return d }
        return nil
    }
}

public struct XAICoreInvoice: Decodable, Encodable, Sendable, Equatable {
    public let amountAfterVat: Double?
    public let prepaidCredits: XAICentsValue?
    public let prepaidCreditsUsed: XAICentsValue?

    enum CodingKeys: String, CodingKey {
        case amountAfterVat = "amountAfterVat"
        case prepaidCredits = "prepaidCredits"
        case prepaidCreditsUsed = "prepaidCreditsUsed"
    }

    public init(amountAfterVat: Double?,
                prepaidCredits: XAICentsValue?,
                prepaidCreditsUsed: XAICentsValue?) {
        self.amountAfterVat = amountAfterVat
        self.prepaidCredits = prepaidCredits
        self.prepaidCreditsUsed = prepaidCreditsUsed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amountAfterVat = Self.numeric(c, .amountAfterVat)
        prepaidCredits = try c.decodeIfPresent(XAICentsValue.self, forKey: .prepaidCredits)
        prepaidCreditsUsed = try c.decodeIfPresent(XAICentsValue.self, forKey: .prepaidCreditsUsed)
    }

    private static func numeric(_ c: KeyedDecodingContainer<CodingKeys>,
                                _ key: CodingKeys) -> Double? {
        if let d = c.flexibleDoubleIfPresent(forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key), let d = Double(s) { return d }
        return nil
    }
}

public struct XAIBillingCycle: Decodable, Encodable, Sendable, Equatable {
    public let year: Int?
    public let month: Int?

    public init(year: Int?, month: Int?) {
        self.year = year
        self.month = month
    }
}

// MARK: - Grok CLI wire types (cli-chat-proxy.grok.com)

public struct GrokBillingResponse: Decodable, Encodable, Sendable, Equatable {
    public let config: GrokBillingConfig?

    enum CodingKeys: String, CodingKey {
        case config
    }

    public init(config: GrokBillingConfig?) {
        self.config = config
    }
}

public struct GrokBillingConfig: Decodable, Encodable, Sendable, Equatable {
    public let currentPeriod: GrokPeriod?
    public let creditUsagePercent: Double?
    public let onDemandCap: XAICentsValue?
    public let onDemandUsed: XAICentsValue?
    public let productUsage: [GrokProductUsage]?
    public let isUnifiedBillingUser: Bool?
    public let prepaidBalance: XAICentsValue?
    public let billingPeriodStart: String?
    public let billingPeriodEnd: String?

    enum CodingKeys: String, CodingKey {
        case currentPeriod
        case creditUsagePercent
        case onDemandCap
        case onDemandUsed
        case productUsage
        case isUnifiedBillingUser
        case prepaidBalance
        case billingPeriodStart
        case billingPeriodEnd
    }

    public init(currentPeriod: GrokPeriod? = nil,
                creditUsagePercent: Double? = nil,
                onDemandCap: XAICentsValue? = nil,
                onDemandUsed: XAICentsValue? = nil,
                productUsage: [GrokProductUsage]? = nil,
                isUnifiedBillingUser: Bool? = nil,
                prepaidBalance: XAICentsValue? = nil,
                billingPeriodStart: String? = nil,
                billingPeriodEnd: String? = nil) {
        self.currentPeriod = currentPeriod
        self.creditUsagePercent = creditUsagePercent
        self.onDemandCap = onDemandCap
        self.onDemandUsed = onDemandUsed
        self.productUsage = productUsage
        self.isUnifiedBillingUser = isUnifiedBillingUser
        self.prepaidBalance = prepaidBalance
        self.billingPeriodStart = billingPeriodStart
        self.billingPeriodEnd = billingPeriodEnd
    }
}

public struct GrokPeriod: Decodable, Encodable, Sendable, Equatable {
    public let type: String?
    public let start: String?
    public let end: String?

    enum CodingKeys: String, CodingKey {
        case type, start, end
    }

    public init(type: String? = nil, start: String? = nil, end: String? = nil) {
        self.type = type
        self.start = start
        self.end = end
    }
}

public struct GrokProductUsage: Decodable, Encodable, Sendable, Equatable {
    public let product: String?
    public let usagePercent: Double?

    enum CodingKeys: String, CodingKey {
        case product, usagePercent
    }

    public init(product: String? = nil, usagePercent: Double? = nil) {
        self.product = product
        self.usagePercent = usagePercent
    }
}

public struct GrokSettingsResponse: Decodable, Encodable, Sendable, Equatable {
    public let subscriptionTierDisplay: String?

    enum CodingKeys: String, CodingKey {
        case subscriptionTierDisplay = "subscription_tier_display"
    }

    public init(subscriptionTierDisplay: String? = nil) {
        self.subscriptionTierDisplay = subscriptionTierDisplay
    }
}

extension GrokBillingResponse {
    public static let defaultDisclaimer = "Para conseguir monitorar o Grok, é necessário ter o Grok instalado e autenticado."

    public func toSnapshot(planLabel: String? = nil, disclaimer: String? = nil) -> XAISnapshot {
        guard let cfg = config else {
            return XAISnapshot(
                planLabel: planLabel ?? "SuperGrok",
                disclaimer: disclaimer ?? Self.defaultDisclaimer
            )
        }

        let util = cfg.creditUsagePercent ?? 0.0

        let resetsAt: Date? = {
            guard let raw = cfg.currentPeriod?.end ?? cfg.billingPeriodEnd else { return nil }
            return ISO8601Parsing.parse(raw)
        }()

        let weeklyWindow = UsageWindow(
            label: "Weekly",
            utilizationPercent: util,
            resetsAt: resetsAt,
            detail: String(format: "%.0f%% used", util)
        )

        let prepaidUSD = cfg.prepaidBalance?.usd
        let balanceWindow: UsageWindow? = {
            guard let usd = prepaidUSD, usd > 0 else { return nil }
            return UsageWindow(
                label: "Balance",
                utilizationPercent: 0,
                resetsAt: nil,
                detail: String(format: "$%.2f available", usd)
            )
        }()

        let prepaidUsedUSD: Double? = {
            if let used = cfg.onDemandUsed?.usd, used > 0 { return used }
            if let pct = cfg.creditUsagePercent, let balance = prepaidUSD, pct > 0 {
                return (balance * pct) / 100.0
            }
            return nil
        }()

        return XAISnapshot(
            planLabel: planLabel ?? "SuperGrok",
            weekly: weeklyWindow,
            balance: balanceWindow,
            monthly: nil,
            prepaidUSD: prepaidUSD,
            spentUSD: nil,
            spendingLimitUSD: nil,
            prepaidUsedUSD: prepaidUsedUSD,
            billingCycleLabel: nil,
            disclaimer: disclaimer ?? Self.defaultDisclaimer
        )
    }
}

// MARK: - Cached multi-endpoint payload

public struct XAICachedPayload: Codable, Sendable, Equatable {
    public let prepaid: XAIPrepaidBalanceResponse?
    public let preview: XAIInvoicePreviewResponse?
    public let grokBilling: GrokBillingResponse?
    public let grokSettings: GrokSettingsResponse?

    public init(prepaid: XAIPrepaidBalanceResponse? = nil,
                preview: XAIInvoicePreviewResponse? = nil,
                grokBilling: GrokBillingResponse? = nil,
                grokSettings: GrokSettingsResponse? = nil) {
        self.prepaid = prepaid
        self.preview = preview
        self.grokBilling = grokBilling
        self.grokSettings = grokSettings
    }

    enum CodingKeys: String, CodingKey {
        case prepaid, preview, grokBilling, grokSettings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prepaid = try c.decodeIfPresent(XAIPrepaidBalanceResponse.self, forKey: .prepaid)
        preview = try c.decodeIfPresent(XAIInvoicePreviewResponse.self, forKey: .preview)
        grokBilling = try c.decodeIfPresent(GrokBillingResponse.self, forKey: .grokBilling)
        grokSettings = try c.decodeIfPresent(GrokSettingsResponse.self, forKey: .grokSettings)
    }
}

extension XAICachedPayload {
    public func toSnapshot() -> XAISnapshot {
        if let grok = grokBilling {
            let label = grokSettings?.subscriptionTierDisplay ?? "SuperGrok"
            return grok.toSnapshot(planLabel: label)
        }

        // Prefer prepaid/balance total; fall back to invoice.prepaidCredits.
        let prepaidCents = prepaid?.total?.val
            ?? preview?.coreInvoice?.prepaidCredits?.val
        let prepaidUSD: Double? = prepaidCents.map { abs($0) / 100.0 }

        let spentCents = preview?.coreInvoice?.amountAfterVat
        let spentUSD = spentCents.map { abs($0) / 100.0 }

        let limitCents = preview?.effectiveSpendingLimit
        let limitUSD = limitCents.map { abs($0) / 100.0 }

        let prepaidUsedUSD = preview?.coreInvoice?.prepaidCreditsUsed?.usd

        var cycleLabel: String?
        if let y = preview?.billingCycle?.year, let m = preview?.billingCycle?.month {
            cycleLabel = String(format: "%04d-%02d", y, m)
        }

        let balanceWindow: UsageWindow? = {
            guard let usd = prepaidUSD else { return nil }
            return UsageWindow(
                label: "Balance",
                utilizationPercent: 0,
                resetsAt: nil,
                detail: String(format: "$%.2f available", usd)
            )
        }()

        let monthlyWindow: UsageWindow? = {
            guard let spent = spentUSD else { return nil }
            let limit = limitUSD ?? 0
            if limit > 0 {
                let pct = min(100, (spent / limit) * 100)
                return UsageWindow(
                    label: cycleLabel.map { "Monthly (\($0))" } ?? "Monthly",
                    utilizationPercent: pct,
                    resetsAt: nil,
                    detail: String(format: "$%.2f / $%.2f", spent, limit)
                )
            }
            return UsageWindow(
                label: cycleLabel.map { "Monthly (\($0))" } ?? "Monthly",
                utilizationPercent: 0,
                resetsAt: nil,
                detail: String(format: "$%.2f spent", spent)
            )
        }()

        return XAISnapshot(
            planLabel: "xAI",
            weekly: nil,
            balance: balanceWindow,
            monthly: monthlyWindow,
            prepaidUSD: prepaidUSD,
            spentUSD: spentUSD,
            spendingLimitUSD: limitUSD,
            prepaidUsedUSD: prepaidUsedUSD,
            billingCycleLabel: cycleLabel,
            disclaimer: GrokBillingResponse.defaultDisclaimer
        )
    }
}
