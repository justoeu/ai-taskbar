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
        existing.inputTokens = saturatingAdd(existing.inputTokens, u.inputTokens)
        existing.outputTokens = saturatingAdd(existing.outputTokens, u.outputTokens)
        existing.cacheReadTokens = saturatingAdd(existing.cacheReadTokens, u.cacheReadTokens)
        existing.cacheCreateTokens = saturatingAdd(existing.cacheCreateTokens, u.cacheCreateTokens)
        existing.cacheCreate1hTokens = saturatingAdd(existing.cacheCreate1hTokens, u.cacheCreate1hTokens)
        existing.longContextInputTokens = saturatingAdd(existing.longContextInputTokens, u.longContextInputTokens)
        existing.longContextOutputTokens = saturatingAdd(existing.longContextOutputTokens, u.longContextOutputTokens)
        existing.longContextCacheReadTokens = saturatingAdd(existing.longContextCacheReadTokens, u.longContextCacheReadTokens)
        existing.longContextCacheCreateTokens = saturatingAdd(existing.longContextCacheCreateTokens, u.longContextCacheCreateTokens)
        existing.longContextCacheCreate1hTokens = saturatingAdd(existing.longContextCacheCreate1hTokens, u.longContextCacheCreate1hTokens)
        bucket[model] = existing
    }

    /// Swift's `+` TRAPS on overflow — it does not wrap. Both token counts
    /// come from files we don't control (`~/.claude/projects`,
    /// `~/.codex/sessions`), so a single line declaring `input_tokens:
    /// 9223372036854775807` would take down the whole menu-bar app with
    /// SIGTRAP, not just fail the scan. Saturating instead of trapping keeps
    /// a corrupt transcript from being a crash: the number shown is absurd,
    /// which is visible and diagnosable, while a dead app is neither.
    /// Wrapping (`&+`) would be worse than either — it silently produces a
    /// small or negative total from a huge one.
    static func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return sum }
        return b > 0 ? Int.max : Int.min
    }

    /// Converts per-model token totals into USD via the supplied pricing
    /// table. Returns the grand total plus a per-model dollar breakdown.
    static func price(totals: [String: ModelUsage],
                      table: [String: ModelPricing]) -> (Double, [String: Double]) {
        var total = 0.0
        var byModel: [String: Double] = [:]
        for (model, usage) in totals {
            // Discovery must not depend on pricing-table freshness. Keeping a
            // zero-dollar row means a newly released model remains visible in
            // the UI while the scanner's note explains that its turns are not
            // priced yet. Previously `continue` erased the model entirely.
            byModel[model] = 0
            guard let pricing = PricingTable.lookup(model, table: table) else { continue }
            let usd = CostMath.cost(usage: usage, pricing: pricing)
            total += usd
            byModel[model] = usd
        }
        return (total, byModel)
    }
}
