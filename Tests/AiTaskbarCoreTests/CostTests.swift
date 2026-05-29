import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("PricingTable + CostMath")
struct CostTests {
    @Test("lookup matches an exact key")
    func lookup_exact() {
        let m = PricingTable.lookup("claude-opus-4-7", table: PricingTable.anthropic)
        #expect(m?.inputPer1M == 15)
        #expect(m?.outputPer1M == 75)
    }

    @Test("lookup falls back to prefix")
    func lookup_prefix_match() {
        // Use a key with no ambiguous parents in the table — moonshot-v1-8k
        // doesn't share a prefix with any other Kimi entry. Dictionary
        // iteration order is undefined, so picking a prefix-unique key is
        // the only way to make this assertion deterministic.
        let m = PricingTable.lookup("moonshot-v1-8k-2026", table: PricingTable.kimi)
        #expect(m?.inputPer1M == 1.0)
    }

    @Test("lookup returns nil on miss")
    func lookup_nil_on_miss() {
        let m = PricingTable.lookup("nonexistent-model", table: PricingTable.openai)
        #expect(m == nil)
    }

    @Test("CostMath accumulates input + output + cache read/create")
    func cost_accumulates_all_buckets() {
        let usage = ModelUsage(inputTokens: 1_000_000,
                               outputTokens: 1_000_000,
                               cacheReadTokens: 1_000_000,
                               cacheCreateTokens: 1_000_000)
        let pricing = ModelPricing(input: 1, output: 2, cacheRead: 0.5, cacheCreate: 4)
        #expect(CostMath.cost(usage: usage, pricing: pricing) == 7.5)
    }

    @Test("CostMath falls back to input price for missing cache prices")
    func cost_falls_back_to_input_for_cache_when_missing() {
        let usage = ModelUsage(inputTokens: 0,
                               outputTokens: 0,
                               cacheReadTokens: 1_000_000,
                               cacheCreateTokens: 1_000_000)
        let pricing = ModelPricing(input: 3, output: 15)  // no cache prices set
        // Both cache types should bill at input price (3) — 2 * 3 = 6.
        #expect(CostMath.cost(usage: usage, pricing: pricing) == 6)
    }

    @Test("CostMath returns zero for empty usage")
    func cost_zero_for_empty_usage() {
        let pricing = ModelPricing(input: 1, output: 1, cacheRead: 1, cacheCreate: 1)
        #expect(CostMath.cost(usage: ModelUsage(), pricing: pricing) == 0)
    }

    @Test("All pricing tables are non-empty")
    func pricing_tables_non_empty() {
        #expect(!PricingTable.anthropic.isEmpty)
        #expect(!PricingTable.openai.isEmpty)
        #expect(!PricingTable.kimi.isEmpty)
    }
}

@Suite("CostEstimate / ModelUsage")
struct CostEstimateTests {
    @Test("CostEstimate default-init carries flags through")
    func cost_estimate_default_flags() {
        let est = CostEstimate(usdToday: 1.2, usdLast7Days: 5.0)
        #expect(est.usdToday == 1.2)
        #expect(est.usdLast7Days == 5.0)
        #expect(est.isApproximate)  // default true
        #expect(est.note == nil)
        #expect(est.modelBreakdownToday.isEmpty)
    }

    @Test("CostEstimate carries note when provided")
    func cost_estimate_with_note() {
        let est = CostEstimate(usdToday: 0, usdLast7Days: 0,
                               isApproximate: false, note: "exact")
        #expect(!est.isApproximate)
        #expect(est.note == "exact")
    }

    @Test("ModelUsage Equatable")
    func model_usage_equatable() {
        let a = ModelUsage(inputTokens: 1, outputTokens: 2)
        let b = ModelUsage(inputTokens: 1, outputTokens: 2)
        let c = ModelUsage(inputTokens: 1, outputTokens: 3)
        #expect(a == b)
        #expect(a != c)
    }
}
