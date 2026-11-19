[← Back to the README](../README.md)

# Cost estimates & pricing

Daily and 7-day costs are computed **locally** from the CLI transcripts (`~/.claude/projects`, `~/.codex/sessions`, opencode's database) and the per-model price table in `PricingTable.swift`, checked against the vendors' published rates (Claude: [platform.claude.com pricing](https://platform.claude.com/docs/en/about-claude/pricing), last verified 2026-11-09).

| Claude model | Input | Output | Cache write 5m / 1h | Cache read | Fast mode (in / out) |
|---|---|---|---|---|---|
| Fable 5.2 · Mythos 5.2 | $8 | $40 | $10 / $16 | $0.20 | $16 / $80 |
| Fable 5.1 · Mythos 5.1 | $10 | $50 | $12.50 / $20 | $0.25 | — |
| Opus 5.5 | $4 | $20 | $5 / $8 | $0.20 | $8 / $40 |
| Opus 5 · Opus 4.8 | $5 | $25 | $6.25 / $10 | $0.50 | $10 / $50 |
| Sonnet 5.5 | $2 | $10 | $2.50 / $4 | $0.10 | — |
| Sonnet 5 | $2 | $10 | $2.50 / $4 | $0.20 | — |
| Haiku 5.5 (prompt ≤ 100K) | $0.10 | $0.50 | $0.125 / $0.20 | $0.01 | — |
| Haiku 5.5 (prompt > 100K) | $0.50 | $2.50 | $0.625 / $1 | $0.05 | — |

Prices per million tokens. **Fast mode** keeps the same model id, so it is detected per request from the transcript's `usage.speed` and billed at 2x on every token category, cache included. Models without fast mode (Opus 4.7 rejects it, Opus 4.6 runs it at standard price) are billed at standard rates. **Haiku 5.5** is priced by prompt length: a request whose prompt (input + cache reads + cache writes) is over 100,000 tokens is billed entirely at the higher row, output included. A model missing from the table still appears in the breakdown, marked as not yet priced, rather than disappearing.

**Kimi K3.1 Pro** (`kimi-k3.1-pro`) is priced at Moonshot's published rate of $2 / $10 per 1M in/out (cache hit $0.20), and `kimi-k3.1-pro-highspeed` at $4 / $20 (cache hit $0.20), flat across the 1M context ([kimi.ai pricing](https://www.kimi.ai/resources/kimi-k3-1-pro-pricing), verified 2026-10-25).

**opencode 1.x and 2.x** are both read: the scanner checks which layout the database has (1.x `message`, 2.x `session_message`) rather than trusting an installed binary's version, so cards keep their opencode rows across the upgrade. When an upgrade leaves both tables, the old one contributes only turns from before the first 2.x turn, so nothing is counted twice or lost.

**Gemini 4 Argon** (`gemini-4-argon`) is priced at Google's introductory rate ($2 / $10 per 1M in/out, cached input $0.10), valid through 2026-11-30; the standard rate from 2026-12-01 is $4 / $20 (cached $0.20). **Gemini 4 Carbon** (`gemini-4-carbon`) carries the same introductory rate ($2 / $10, cached $0.10) through 2026-11-30 and the same $4 / $20 from 2026-12-01. **Gemini 4 Neon** (`gemini-4-neon`, launched 2026-11-18) is $3 / $15 (cached $0.15) and **Gemini 4 Hydrogen** (`gemini-4-hydrogen`) $1.50 / $7.50 (cached $0.075). Other Gemini 4 variants fall back to a `gemini-4` prefix at the introductory tier. `gemini-3.8-flash` and `gemini-3.6-flash` are $0.75 / $3.75 (cached $0.075) until 2026-12-31, then $1.50 / $7.50. Gemini 3.1 Pro's >200K tier is in the table but not yet applied: the Gemini scanner does not tag long prompts per request ([Gemini API pricing](https://aistudio.google.com/docs/pricing), verified 2026-11-18).

**GPT-6.2 Astra** (`gpt-6.2-astra`) is priced at $8 / $40 per 1M in/out (cached $0.40) and **GPT-6.2 Sol** (`gpt-6.2-sol`) at $2 / $10 (cached $0.10); prompts over 272K tokens bill 2x input and 1.5x output for the whole request ([OpenAI pricing](https://developers.openai.com/api/docs/pricing), verified 2026-11-18).


