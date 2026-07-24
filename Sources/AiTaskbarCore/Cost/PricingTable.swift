import Foundation

/// USD price per 1 million tokens. Values reflect the public price lists as of
/// 2026-06-14; intentionally conservative when a model isn't listed. Update as
/// new models ship.
///
/// Only `anthropic` and `openai` are defined here — they are the **only** two
/// tables consulted at runtime (`ClaudeSessionScanner`, `CodexSessionScanner`,
/// and the legacy `CodexLogScanner` compute cost locally from on-disk CLI
/// logs). Gemini, Kimi, OpenRouter, and
/// Z.AI all surface usage/cost/balance straight from each vendor's own API, so
/// they never touch this table. Don't add a vendor table here unless a local
/// log scanner actually prices against it — otherwise it's dead code that rots
/// out of date and misleads (see git history: stale `gemini`/`kimi` tables).
public struct ModelPricing: Sendable, Equatable {
    public let inputPer1M: Double
    public let outputPer1M: Double
    /// Cache read tokens are billed at ~10% of input price (Anthropic) or 0
    /// (OpenAI cached tier). Falls back to input price when unknown.
    public let cacheReadPer1M: Double?
    /// Cache creation is ~125% of input (Anthropic). Falls back to input.
    /// OpenAI has no per-token cache-creation fee, so it's left nil there.
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
    /// Anthropic — Claude family. Consumed by `ClaudeSessionScanner`.
    public static let anthropic: [String: ModelPricing] = [
        // Fable 5 — most capable; priced above Opus-tier ($10 in / $50 out).
        "claude-fable-5":        ModelPricing(input: 10, output: 50, cacheRead: 1.0, cacheCreate: 12.5),
        "claude-mythos-5":       ModelPricing(input: 10, output: 50, cacheRead: 1.0, cacheCreate: 12.5),
        // Opus 5 — same $5 in / $25 out tier as Opus 4.8 (verified against the
        // claude-api skill's cached model table, 2026-07-24). Listed before the
        // 4.x block because it shares no prefix with them: "claude-opus-5" can
        // never be shadowed by "claude-opus-4", so ordering here is cosmetic.
        "claude-opus-5":         ModelPricing(input: 5,  output: 25, cacheRead: 0.5, cacheCreate: 6.25),
        // Opus 4.5–4.8 — repriced to $5 in / $25 out (down from the 4.0/4.1 tier).
        // Each version is listed explicitly so the `claude-opus-4` prefix below
        // (which still serves the legacy 4.0/4.1 at $15/$75) doesn't shadow them.
        "claude-opus-4-8":       ModelPricing(input: 5,  output: 25, cacheRead: 0.5, cacheCreate: 6.25),
        "claude-opus-4-7":       ModelPricing(input: 5,  output: 25, cacheRead: 0.5, cacheCreate: 6.25),
        "claude-opus-4-6":       ModelPricing(input: 5,  output: 25, cacheRead: 0.5, cacheCreate: 6.25),
        "claude-opus-4-5":       ModelPricing(input: 5,  output: 25, cacheRead: 0.5, cacheCreate: 6.25),
        // Legacy Opus 4.0 / 4.1 — prefix fallback for any unlisted claude-opus-4*.
        "claude-opus-4":         ModelPricing(input: 15, output: 75, cacheRead: 1.5, cacheCreate: 18.75),
        // Sonnet 5 — sticker $3/$15, but intro pricing $2/$10 is in effect
        // through 2026-08-31 (verified via the claude-api skill's cached
        // model table, 2026-06-24). Bump to input:3/output:15/cacheRead:0.3/
        // cacheCreate:3.75 after that date.
        "claude-sonnet-5":       ModelPricing(input: 2,  output: 10, cacheRead: 0.2, cacheCreate: 2.5),
        // Sonnet 4.x
        "claude-sonnet-4-6":     ModelPricing(input: 3,  output: 15, cacheRead: 0.3, cacheCreate: 3.75),
        "claude-sonnet-4":       ModelPricing(input: 3,  output: 15, cacheRead: 0.3, cacheCreate: 3.75),
        // Haiku 4.5
        "claude-haiku-4-5":      ModelPricing(input: 1,  output: 5,  cacheRead: 0.1, cacheCreate: 1.25),
    ]

    /// OpenAI — GPT-5 family. Consumed by `CodexSessionScanner` (and the legacy
    /// `CodexLogScanner`); Codex reports rolled-up model strings, sometimes
    /// date- or deployment-suffixed → prefix match.
    /// Verified against developers.openai.com/api/docs/pricing on 2026-06-14.
    /// OpenAI bills cached input (~10% of input) but has no cache-creation fee.
    public static let openai: [String: ModelPricing] = [
        // GPT-5.6 — shipped publicly as three named variants (Sol/Terra/Luna).
        // Verified against developers.openai.com/api/docs/pricing on
        // 2026-07-24. There is NO bare `gpt-5.6`, no `gpt-5.6-pro` and no
        // `gpt-5.6-mini` — do not re-add them. `gpt-5.6-sol` is what Codex
        // writes to its rollout logs on this line.
        "gpt-5.6-sol":     ModelPricing(input: 5,    output: 30,   cacheRead: 0.5),
        "gpt-5.6-terra":   ModelPricing(input: 2.5,  output: 15,   cacheRead: 0.25),
        "gpt-5.6-luna":    ModelPricing(input: 1,    output: 6,    cacheRead: 0.1),
        // Conservative catch-all for a 5.6 variant OpenAI ships later: without
        // it an unknown `gpt-5.6-*` falls all the way back to `gpt-5` ($1.25)
        // and under-reports by 4x. Priced at the most expensive real variant
        // so a new model errs toward over-reporting, which is visible, rather
        // than under-reporting, which is not. The three keys above win by
        // longest-prefix, so this never shadows a known variant.
        "gpt-5.6":         ModelPricing(input: 5,    output: 30,   cacheRead: 0.5),
        // GPT-5.5 (shipped 2026-04-23).
        "gpt-5.5":         ModelPricing(input: 5,    output: 30,   cacheRead: 0.5),
        // GPT-5.4 line.
        "gpt-5.4-mini":    ModelPricing(input: 0.75, output: 4.5,  cacheRead: 0.075),
        "gpt-5.4-nano":    ModelPricing(input: 0.20, output: 1.25, cacheRead: 0.02),
        "gpt-5.4":         ModelPricing(input: 2.5,  output: 15,   cacheRead: 0.25),
        // The `-pro` models have NO prompt caching (confirmed on the pricing
        // page). `cacheRead` is therefore deliberately absent, not an
        // oversight: these models can never report cached tokens, so the
        // `cacheReadPer1M ?? inputPer1M` fallback in `CostMath` is unreachable
        // for them. Don't "fix" it by inventing a cached rate.
        "gpt-5.5-pro":     ModelPricing(input: 30,   output: 180),
        "gpt-5.4-pro":     ModelPricing(input: 30,   output: 180),
        // Codex flagship.
        "gpt-5.3-codex":   ModelPricing(input: 1.75, output: 14,   cacheRead: 0.175),
        // `codex-auto-review` is the model alias Codex writes to its rollout
        // logs for the automatic review pass (observed in
        // ~/.codex/sessions/**/rollout-*.jsonl and in state_5.sqlite's
        // `threads.model`). OpenAI publishes no separate rate for it, so we
        // price it at the Codex flagship tier — an ESTIMATE. Without an entry
        // here `lookup` returns nil and every review turn silently costs $0,
        // which under-reports far worse than a wrong-but-close rate. Replace
        // once OpenAI documents the alias.
        "codex-auto-review": ModelPricing(input: 1.75, output: 14, cacheRead: 0.175),
        // Legacy GPT-5.0 line — delisted from the public page but kept as a
        // prefix fallback for older Codex logs.
        "gpt-5-codex":     ModelPricing(input: 1.25, output: 10,   cacheRead: 0.125),
        "gpt-5-mini":      ModelPricing(input: 0.25, output: 2,    cacheRead: 0.025),
        "gpt-5":           ModelPricing(input: 1.25, output: 10,   cacheRead: 0.125),
    ]

    public static func lookup(_ model: String, table: [String: ModelPricing]) -> ModelPricing? {
        if let exact = table[model] { return exact }
        // Longest-prefix wins. Log lines may carry suffixes ("gpt-5.5-2026-04",
        // "claude-opus-4-8-thinking"); with overlapping keys ("gpt-5", "gpt-5.4",
        // "gpt-5.4-mini") a first-match scan is nondeterministic because
        // dictionary order is undefined. Pick the most specific (longest) key.
        return table
            .filter { model.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}
