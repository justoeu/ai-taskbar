import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("PricingTable + CostMath")
struct CostTests {
    @Test("lookup matches an exact key")
    func lookup_exact() {
        let m = PricingTable.lookup("claude-opus-4-7", table: PricingTable.anthropic)
        #expect(m?.inputPer1M == 5)
        #expect(m?.outputPer1M == 25)
    }

    @Test("Fable 5 has explicit pricing (not silently dropped)")
    func lookup_fable() {
        let m = PricingTable.lookup("claude-fable-5", table: PricingTable.anthropic)
        #expect(m?.inputPer1M == 10)
        #expect(m?.outputPer1M == 50)
    }

    @Test("legacy Opus 4.0/4.1 still price at the old tier via prefix")
    func lookup_legacy_opus() {
        let m = PricingTable.lookup("claude-opus-4-1", table: PricingTable.anthropic)
        #expect(m?.inputPer1M == 15)
        #expect(m?.outputPer1M == 75)
    }

    @Test("Sonnet 5 has explicit intro pricing")
    func lookup_sonnet5() {
        let m = PricingTable.lookup("claude-sonnet-5", table: PricingTable.anthropic)
        #expect(m?.inputPer1M == 2)
        #expect(m?.outputPer1M == 10)
    }

    @Test("GPT-5.6 has an explicit entry, not silently prefix-dropped to gpt-5")
    func lookup_gpt56() {
        let m = PricingTable.lookup("gpt-5.6", table: PricingTable.openai)
        #expect(m?.inputPer1M == 5)
        #expect(m?.outputPer1M == 30)
    }

    @Test("GPT-5.6 variants resolve via longest-prefix match")
    func lookup_gpt56_variants() {
        let pro = PricingTable.lookup("gpt-5.6-pro", table: PricingTable.openai)
        #expect(pro?.inputPer1M == 30)
        let mini = PricingTable.lookup("gpt-5.6-mini", table: PricingTable.openai)
        #expect(mini?.inputPer1M == 0.75)
    }

    @Test("lookup falls back to prefix")
    func lookup_prefix_match() {
        // Date-suffixed model id resolves to its base entry via prefix match.
        let m = PricingTable.lookup("gpt-5.5-2026-04", table: PricingTable.openai)
        #expect(m?.inputPer1M == 5)
    }

    @Test("lookup prefers the longest matching prefix")
    func lookup_longest_prefix_wins() {
        // "gpt-5.4-mini-..." also has prefixes "gpt-5" and "gpt-5.4" in the
        // table. Longest-prefix-wins must pick gpt-5.4-mini ($0.75), not the
        // shorter, pricier gpt-5 ($1.25) or gpt-5.4 ($2.50). Dictionary order
        // is undefined, so a first-match scan would be nondeterministic.
        let m = PricingTable.lookup("gpt-5.4-mini-2026-05", table: PricingTable.openai)
        #expect(m?.inputPer1M == 0.75)
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
