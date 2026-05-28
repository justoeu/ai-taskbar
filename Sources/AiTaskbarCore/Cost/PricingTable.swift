import Foundation

/// USD price per 1 million tokens. Values are approximate and reflect the
/// public price lists as of 2026-05; intentionally conservative when a model
/// isn't listed. Update as new models ship.
public struct ModelPricing: Sendable, Equatable {
    public let inputPer1M: Double
    public let outputPer1M: Double
    /// Cache read tokens are billed at ~10% of input price (Anthropic) or 0
    /// (OpenAI cached tier). Falls back to input price when unknown.
    public let cacheReadPer1M: Double?
    /// Cache creation is ~125% of input (Anthropic). Falls back to input.
    public let cacheCreatePer1M: Double?

    public init(input: Double, output: Double,
                cacheRead: Double? = nil, cacheCreate: Double? = nil) {
        self.inputPer1M = input
        self.outputPer1M = output
        self.cacheReadPer1M = cacheRead
        self.cacheCreatePer1M = cacheCreate
    }
}

public enum PricingTable {
    /// Anthropic — Claude family.
    public static let anthropic: [String: ModelPricing] = [
        // Opus 4.x
        "claude-opus-4-7":       ModelPricing(input: 15, output: 75, cacheRead: 1.5, cacheCreate: 18.75),
        "claude-opus-4-6":       ModelPricing(input: 15, output: 75, cacheRead: 1.5, cacheCreate: 18.75),
        "claude-opus-4":         ModelPricing(input: 15, output: 75, cacheRead: 1.5, cacheCreate: 18.75),
        // Sonnet 4.x
        "claude-sonnet-4-6":     ModelPricing(input: 3,  output: 15, cacheRead: 0.3, cacheCreate: 3.75),
        "claude-sonnet-4":       ModelPricing(input: 3,  output: 15, cacheRead: 0.3, cacheCreate: 3.75),
        // Haiku 4.5
        "claude-haiku-4-5":      ModelPricing(input: 1,  output: 5,  cacheRead: 0.1, cacheCreate: 1.25),
    ]

    /// Moonshot / Kimi — pricing per platform.kimi.ai (verified 2026-05).
    public static let kimi: [String: ModelPricing] = [
        // K2.6 — input cache-miss $0.95 / cache-hit $0.16 / output $4.00
        "kimi-k2-6":       ModelPricing(input: 0.95, output: 4.00, cacheRead: 0.16),
        "kimi-k2.6":       ModelPricing(input: 0.95, output: 4.00, cacheRead: 0.16),
        "kimi-k2":         ModelPricing(input: 0.95, output: 4.00, cacheRead: 0.16),
        // Older models — conservative placeholders; update when published.
        "moonshot-v1-8k":  ModelPricing(input: 1.0, output: 2.0, cacheRead: 0.1),
        "moonshot-v1-32k": ModelPricing(input: 2.0, output: 4.0, cacheRead: 0.2),
        "moonshot-v1-128k":ModelPricing(input: 8.0, output: 16.0, cacheRead: 0.8),
    ]

    /// OpenAI — gpt-5 family. Codex's logs report rolled-up `model=` strings.
    public static let openai: [String: ModelPricing] = [
        "gpt-5.5":               ModelPricing(input: 2,    output: 10,  cacheRead: 0.2),
        "gpt-5":                 ModelPricing(input: 1.25, output: 10,  cacheRead: 0.125),
        "gpt-5-codex":           ModelPricing(input: 1.25, output: 10,  cacheRead: 0.125),
        "gpt-5-mini":            ModelPricing(input: 0.25, output: 2,   cacheRead: 0.025),
    ]

    public static func lookup(_ model: String, table: [String: ModelPricing]) -> ModelPricing? {
        if let exact = table[model] { return exact }
        // Try a prefix match — log lines may include suffixes like "model=gpt-5.5-2026-01".
        for (key, price) in table where model.hasPrefix(key) {
            return price
        }
        return nil
    }
}
