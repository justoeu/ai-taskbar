import Foundation

public struct ModelUsage: Sendable, Equatable {
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreateTokens: Int = 0

    public init(inputTokens: Int = 0, outputTokens: Int = 0,
                cacheReadTokens: Int = 0, cacheCreateTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreateTokens = cacheCreateTokens
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

    public init(usdToday: Double,
                usdLast7Days: Double,
                modelBreakdownToday: [String: Double] = [:],
                modelBreakdownLast7Days: [String: Double] = [:],
                totalsByModel: [String: ModelUsage] = [:],
                computedAt: Date = .init(),
                isApproximate: Bool = true,
                note: String? = nil) {
        self.usdToday = usdToday
        self.usdLast7Days = usdLast7Days
        self.modelBreakdownToday = modelBreakdownToday
        self.modelBreakdownLast7Days = modelBreakdownLast7Days
        self.totalsByModel = totalsByModel
        self.computedAt = computedAt
        self.isApproximate = isApproximate
        self.note = note
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
        return inputCost + outputCost + cacheRead + cacheCreate
    }
}
