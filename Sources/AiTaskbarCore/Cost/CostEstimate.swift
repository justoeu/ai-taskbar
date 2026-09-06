import Foundation

public struct ModelUsage: Sendable, Equatable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    /// Prompt-cache writes whose TTL is unknown or five minutes.
    public var cacheCreateTokens: Int = 0
    /// Anthropic exposes one-hour cache writes separately and charges a
    /// different rate for them, so they cannot share the five-minute bucket.
    public var cacheCreate1hTokens: Int = 0
    /// Subsets of the totals above that came from a request over a model's
    /// long-context threshold. They carry only the pricing surcharge; keeping
    /// them as subsets preserves the user-facing total token counts.
    public var longContextInputTokens: Int = 0
    public var longContextOutputTokens: Int = 0
    public var longContextCacheReadTokens: Int = 0
    public var longContextCacheCreateTokens: Int = 0
    public var longContextCacheCreate1hTokens: Int = 0

    public init(inputTokens: Int = 0, outputTokens: Int = 0,
                cacheReadTokens: Int = 0, cacheCreateTokens: Int = 0,
                cacheCreate1hTokens: Int = 0,
                longContextInputTokens: Int = 0,
                longContextOutputTokens: Int = 0,
                longContextCacheReadTokens: Int = 0,
                longContextCacheCreateTokens: Int = 0,
                longContextCacheCreate1hTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreateTokens = cacheCreateTokens
        self.cacheCreate1hTokens = cacheCreate1hTokens
        self.longContextInputTokens = longContextInputTokens
        self.longContextOutputTokens = longContextOutputTokens
        self.longContextCacheReadTokens = longContextCacheReadTokens
        self.longContextCacheCreateTokens = longContextCacheCreateTokens
        self.longContextCacheCreate1hTokens = longContextCacheCreate1hTokens
    }
}

public struct CostEstimate: Sendable, Equatable {
    public let usdToday: Double
    public let usdLast7Days: Double
    public let modelBreakdownToday: [String: Double]      // model → USD (today)
    public let modelBreakdownLast7Days: [String: Double]  // model → USD (last 7 days)
    public let totalsByModel: [String: ModelUsage]
    public let computedAt: Date
    public let isApproximate: Bool
    public let note: String?
    /// Explicitly distinguishes an unknown price from a known $0 amount.
    public let unpricedModelsToday: Set<String>
    public let unpricedModelsLast7Days: Set<String>

    /// Whether the cost footer has either money or a discovered model to show.
    /// An unpriced newly released model has a zero-dollar breakdown entry and
    /// must remain visible instead of making the entire footer disappear.
    public var hasDisplayData: Bool {
        usdToday > 0 || usdLast7Days > 0
            || !modelBreakdownToday.isEmpty
            || !modelBreakdownLast7Days.isEmpty
    }

    public init(usdToday: Double,
                usdLast7Days: Double,
                modelBreakdownToday: [String: Double] = [:],
                modelBreakdownLast7Days: [String: Double] = [:],
                totalsByModel: [String: ModelUsage] = [:],
                computedAt: Date = .init(),
                isApproximate: Bool = true,
                note: String? = nil,
                unpricedModelsToday: Set<String> = [],
                unpricedModelsLast7Days: Set<String> = []) {
        self.usdToday = usdToday
        self.usdLast7Days = usdLast7Days
        self.modelBreakdownToday = modelBreakdownToday
        self.modelBreakdownLast7Days = modelBreakdownLast7Days
        self.totalsByModel = totalsByModel
        self.computedAt = computedAt
        self.isApproximate = isApproximate
        self.note = note
        self.unpricedModelsToday = unpricedModelsToday
        self.unpricedModelsLast7Days = unpricedModelsLast7Days
    }
}

public enum CostMath {
    public static func cost(usage: ModelUsage, pricing: ModelPricing) -> Double {
        let per: (Int, Double) -> Double = { Double($0) / 1_000_000 * $1 }
        let inputCost   = per(usage.inputTokens, pricing.inputPer1M)
        let outputCost  = per(usage.outputTokens, pricing.outputPer1M)
        let cacheRead   = per(usage.cacheReadTokens,
                              pricing.cacheReadPer1M ?? pricing.inputPer1M)
        let cacheCreate = per(usage.cacheCreateTokens,
                              pricing.cacheCreatePer1M ?? pricing.inputPer1M)
        let cacheCreate1h = per(
            usage.cacheCreate1hTokens,
            pricing.cacheCreate1hPer1M
                ?? pricing.cacheCreatePer1M
                ?? pricing.inputPer1M)

        // Long-context fields are subsets already included above. Charge only
        // the difference between long- and short-context rates here.
        let inputMultiplier = pricing.longContextInputMultiplier ?? 1
        let outputMultiplier = pricing.longContextOutputMultiplier ?? 1
        let longInput = per(
            usage.longContextInputTokens,
            pricing.inputPer1M * (inputMultiplier - 1))
        let longOutput = per(
            usage.longContextOutputTokens,
            pricing.outputPer1M * (outputMultiplier - 1))
        let cacheReadRate = pricing.cacheReadPer1M ?? pricing.inputPer1M
        let cacheCreateRate = pricing.cacheCreatePer1M ?? pricing.inputPer1M
        let cacheCreate1hRate = pricing.cacheCreate1hPer1M ?? cacheCreateRate
        let longCacheRead = per(
            usage.longContextCacheReadTokens,
            cacheReadRate * (inputMultiplier - 1))
        let longCacheCreate = per(
            usage.longContextCacheCreateTokens,
            cacheCreateRate * (inputMultiplier - 1))
        let longCacheCreate1h = per(
            usage.longContextCacheCreate1hTokens,
            cacheCreate1hRate * (inputMultiplier - 1))
        return inputCost + outputCost + cacheRead + cacheCreate + cacheCreate1h
            + longInput + longOutput + longCacheRead
            + longCacheCreate + longCacheCreate1h
    }
}
