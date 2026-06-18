import Foundation

/// Shared cost-tallying helpers extracted from `ClaudeSessionScanner` and
/// `CodexLogScanner` — both had byte-identical `add(_:into:model:)` and
/// `price(totals:table:)` implementations. Centralizing them removes the
/// copy-paste maintenance hazard (a tweak to one would silently desync the
/// Claude vs Codex totals).
enum CostAggregator {
    /// Accumulates a per-model `ModelUsage` sample into a totals bucket,
    /// mutating the existing entry if the model has been seen before.
    static func add(_ u: ModelUsage,
                    into bucket: inout [String: ModelUsage],
                    model: String) {
        var existing = bucket[model] ?? ModelUsage()
        existing.inputTokens += u.inputTokens
        existing.outputTokens += u.outputTokens
        existing.cacheReadTokens += u.cacheReadTokens
        existing.cacheCreateTokens += u.cacheCreateTokens
        bucket[model] = existing
    }

    /// Converts per-model token totals into USD via the supplied pricing
    /// table. Returns the grand total plus a per-model dollar breakdown.
    static func price(totals: [String: ModelUsage],
                      table: [String: ModelPricing]) -> (Double, [String: Double]) {
        var total = 0.0
        var byModel: [String: Double] = [:]
        for (model, usage) in totals {
            guard let pricing = PricingTable.lookup(model, table: table) else { continue }
            let usd = CostMath.cost(usage: usage, pricing: pricing)
            total += usd
            byModel[model] = usd
        }
        return (total, byModel)
    }
}
