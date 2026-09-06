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

    @Test("Fable 5.1 has its current lower cache-read price")
    func lookup_fable51() {
        let m = PricingTable.lookup("claude-fable-5-1", table: PricingTable.anthropic)
        #expect(m?.inputPer1M == 10)
        #expect(m?.outputPer1M == 50)
        #expect(m?.cacheReadPer1M == 0.25)
        #expect(m?.cacheCreatePer1M == 12.5)
    }

    @Test("Opus 5 has explicit pricing at the $5/$25 tier")
    func lookup_opus5() {
        let m = PricingTable.lookup("claude-opus-5", table: PricingTable.anthropic)
        #expect(m?.inputPer1M == 5)
        #expect(m?.outputPer1M == 25)
        #expect(m?.cacheReadPer1M == 0.5)
        #expect(m?.cacheCreatePer1M == 6.25)
    }

    /// Session logs carry suffixed ids ("claude-opus-5-thinking"). The prefix
    /// fallback must land on Opus 5's own entry — and critically NOT on
    /// "claude-opus-4", which is a different (legacy, 3× pricier) tier.
    @Test("Opus 5 suffixed variants resolve to Opus 5, not the legacy Opus 4 tier")
    func lookup_opus5_variant() {
        let m = PricingTable.lookup("claude-opus-5-thinking", table: PricingTable.anthropic)
        #expect(m?.inputPer1M == 5)
        #expect(m?.outputPer1M == 25)
    }

    /// Codex writes deployment-suffixed ids to its rollout logs. "gpt-5.6-sol"
    /// must resolve to gpt-5.6 ($4) — a first-match scan could pick gpt-5
    /// ($1.25) and under-report by more than 3×.
    @Test("Codex's gpt-5.6-sol resolves to the gpt-5.6 tier")
    func lookup_gpt56_sol() {
        let m = PricingTable.lookup("gpt-5.6-sol", table: PricingTable.openai)
        #expect(m?.inputPer1M == 4)
        #expect(m?.outputPer1M == 20)
        #expect(m?.cacheReadPer1M == 0.4)
    }

    @Test("GPT-6 Astra has explicit current pricing")
    func lookup_gpt6_astra() {
        let m = PricingTable.lookup("gpt-6-astra", table: PricingTable.openai)
        #expect(m?.inputPer1M == 10)
        #expect(m?.outputPer1M == 50)
        #expect(m?.cacheReadPer1M == 1)
        #expect(m?.cacheCreatePer1M == 12.5)
    }

    /// Codex's auto-review alias has no published rate; an explicit estimate
    /// beats `nil`, which would silently price every review turn at $0.
    @Test("codex-auto-review is priced rather than silently dropped")
    func lookup_codex_auto_review() {
        let m = PricingTable.lookup("codex-auto-review", table: PricingTable.openai)
        #expect(m?.inputPer1M == 1.75)
        #expect(m?.outputPer1M == 14)
    }

    @Test("legacy Opus 4.0/4.1 still price at the old tier via prefix")
    func lookup_legacy_opus() {
        let m = PricingTable.lookup("claude-opus-4-1", table: PricingTable.anthropic)
        #expect(m?.inputPer1M == 15)
        #expect(m?.outputPer1M == 75)
    }

    @Test("Sonnet 5 has explicit current pricing")
    func lookup_sonnet5() {
        let m = PricingTable.lookup("claude-sonnet-5", table: PricingTable.anthropic)
        #expect(m?.inputPer1M == 2)
        #expect(m?.outputPer1M == 10)
    }

    /// The general-purpose GPT-5.6 variants each have their own tier. Cyber is
    /// pinned separately below because its restricted model page carries a
    /// materially higher base rate.
    /// A single bare `gpt-5.6` key used to catch these by prefix, which
    /// over-reported terra by 2x and luna by 5x — invisible on a machine that
    /// only runs sol.
    @Test("each real GPT-5.6 variant prices at its own tier")
    func lookup_gpt56_variants() {
        let sol = PricingTable.lookup("gpt-5.6-sol", table: PricingTable.openai)
        #expect(sol?.inputPer1M == 4)
        #expect(sol?.outputPer1M == 20)
        let terra = PricingTable.lookup("gpt-5.6-terra", table: PricingTable.openai)
        #expect(terra?.inputPer1M == 2)
        #expect(terra?.outputPer1M == 12)
        let luna = PricingTable.lookup("gpt-5.6-luna", table: PricingTable.openai)
        #expect(luna?.inputPer1M == 0.2)
        #expect(luna?.outputPer1M == 1.2)
    }

    @Test("GPT-5.6 Cyber has its exact restricted-model pricing")
    func lookup_gpt56_cyber() {
        let cyber = PricingTable.lookup("gpt-5.6-cyber", table: PricingTable.openai)
        #expect(cyber?.inputPer1M == 12.5)
        #expect(cyber?.outputPer1M == 75)
        #expect(cyber?.cacheReadPer1M == 1.25)
        #expect(cyber?.cacheCreatePer1M == 15.625)
        #expect(cyber?.longContextThresholdTokens == 272_000)
        #expect(cyber?.longContextInputMultiplier == 2)
        #expect(cyber?.longContextOutputMultiplier == 1.5)
    }

    /// An unlisted 5.6 variant must land on the 5.6 catch-all, NOT fall
    /// through to `gpt-5` ($1.25) — that would under-report by 4x, and
    /// under-reporting is the failure mode nobody notices.
    @Test("unknown GPT-5.6 variant hits the 5.6 catch-all, not gpt-5")
    func lookup_gpt56_unknown_variant() {
        let m = PricingTable.lookup("gpt-5.6-nova", table: PricingTable.openai)
        #expect(m?.inputPer1M == 4)
    }

    /// `gpt-5.6-pro` and `gpt-5.6-mini` do not exist. Asserting their absence
    /// keeps a future edit from re-adding fiction the gate would then defend.
    @Test("fictional GPT-5.6 variants are not exact keys")
    func no_fictional_gpt56_keys() {
        #expect(PricingTable.openai["gpt-5.6-pro"] == nil)
        #expect(PricingTable.openai["gpt-5.6-mini"] == nil)
    }

    /// The `-pro` models have no prompt caching, so `cacheReadPer1M` is nil by
    /// design. `CostMath` falls back to the INPUT rate ($30/MTok) for cached
    /// tokens — harmless only while those models truly report none. This pins
    /// the reasoning so a stray cached count can't quietly bill 60x.
    @Test("pro tiers carry no cache rate and fall back to input")
    func pro_tier_cache_fallback_is_explicit() {
        let pro = PricingTable.lookup("gpt-5.5-pro", table: PricingTable.openai)
        #expect(pro?.cacheReadPer1M == nil)
        let usage = ModelUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 1_000_000)
        #expect(CostMath.cost(usage: usage, pricing: pro!) == 30)
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

    @Test("unpriced models remain in the breakdown at zero dollars")
    func unpriced_models_remain_visible() {
        let totals = ["future-model": ModelUsage(inputTokens: 1_000)]
        let (total, breakdown) = CostAggregator.price(totals: totals, table: [:])
        #expect(total == 0)
        #expect(breakdown["future-model"] == 0)
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

    @Test("an unpriced model breakdown still counts as displayable data")
    func unpriced_breakdown_is_displayable() {
        let est = CostEstimate(
            usdToday: 0,
            usdLast7Days: 0,
            modelBreakdownLast7Days: ["future-model": 0]
        )
        #expect(est.hasDisplayData)
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
