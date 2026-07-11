import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// **Golden / immutability tests.** Each vendor's canonical fixture decodes
/// into a `VendorSnapshot` whose every field is pinned against a reference
/// value below. Any drift in the wire decoders OR in the public Snapshot
/// shape MUST surface here — the Snapshot is a contract, not an
/// implementation detail.
///
/// To intentionally change a Snapshot shape:
/// 1. Update the reference values below.
/// 2. Bump the version note in CLAUDE.md if the change is breaking.
/// 3. Re-run `make validate`.
///
/// The reference values live inline in this file (rather than in a
/// separate golden directory) so a PR diff makes the contract change
/// visible alongside the code change.
@Suite("Golden / immutability tests for vendor wire types")
struct GoldenSnapshotTests {
    // MARK: - Anthropic

    @Test("Anthropic golden — 5h session + 7d weekly + extra usage")
    func anthropic_golden() throws {
        let parsed = try JSONDecoder().decode(
            AnthropicUsageResponse.self,
            from: Fixtures.data(Fixtures.anthropicUsage200))
        let snap = parsed.toSnapshot(planLabel: "Claude Max 5x")

        // Pinned values — touching the decoder must touch this list.
        #expect(snap.planLabel == "Claude Max 5x")
        #expect(snap.session?.label == "Session (5h)")
        #expect(Int((snap.session?.utilizationPercent ?? 0).rounded()) == 47)
        #expect(snap.weekly?.label == "Weekly (7d)")
        #expect(Int((snap.weekly?.utilizationPercent ?? 0).rounded()) == 12)
        // Opus window present, pinned to the wire-type label (was a tautology
        // `== "Sonnet/Opus (7d)" || snap.opus != nil` — always true when opus
        // non-nil; the source actually emits "Opus (7d)").
        #expect(snap.opus?.label == "Opus (7d)")
        // Model-scoped window (Fable) from the generic `limits[]` array.
        #expect(snap.scoped.count == 1)
        #expect(snap.scoped.first?.label == "Fable (7d)")
        #expect(Int((snap.scoped.first?.utilizationPercent ?? 0).rounded()) == 88)
        // Usage credits window: percent + deterministic money detail.
        #expect(snap.credits?.label == "Usage credits")
        #expect(Int((snap.credits?.utilizationPercent ?? 0).rounded()) == 12)
        #expect(snap.credits?.detail == "$2.45 / $20.00")
    }

    // MARK: - OpenAI

    @Test("OpenAI golden — primary/secondary windows + credits + cloud range")
    func openai_golden() throws {
        let parsed = try JSONDecoder().decode(
            OpenAIUsageResponse.self,
            from: Fixtures.data(Fixtures.openaiUsage200))
        let snap = parsed.toSnapshot(
            planLabel: "ChatGPT Plus",
            fallbackNow: Date(timeIntervalSince1970: 1_764_000_000))

        #expect(snap.planLabel == "ChatGPT Plus")
        #expect(snap.primary?.label == "Session (5h)")
        #expect(Int((snap.primary?.utilizationPercent ?? 0).rounded()) == 33)
        #expect(snap.secondary?.label == "Weekly (7d)")
        #expect(Int((snap.secondary?.utilizationPercent ?? 0).rounded()) == 5)
        #expect(snap.creditsUSD == 4.20)
        #expect(snap.messageCountRange == "≈ 5–10 local msgs left")
    }

    // MARK: - OpenRouter

    @Test("OpenRouter golden — credits + key + activity combined snapshot")
    func openrouter_golden() throws {
        let credits = try JSONDecoder().decode(
            OpenRouterCreditsResponse.self,
            from: Fixtures.data(Fixtures.openrouterCredits200))
        let key = try JSONDecoder().decode(
            OpenRouterKeyResponse.self,
            from: Fixtures.data(Fixtures.openrouterKey200))
        let activity = try JSONDecoder().decode(
            OpenRouterActivityResponse.self,
            from: Fixtures.data(Fixtures.openrouterActivity200))
        let snap = OpenRouterCachedPayload(credits: credits, key: key, activity: activity).toSnapshot()

        #expect(snap.planLabel == "OpenRouter: primary")
        // total_credits=10, total_usage=2.50 → 25%.
        #expect(Int((snap.balance?.utilizationPercent ?? 0).rounded()) == 25)
        // key.usage=2.50 / key.limit=10 → 25%.
        #expect(Int((snap.monthly?.utilizationPercent ?? 0).rounded()) == 25)
        // model aggregation from activity: 3.20 + 2.10 + 1.50 = 6.80 total
        #expect(snap.topModels?.map(\.model) == [
            "openai/gpt-4.1",
            "anthropic/claude-sonnet-4.6",
            "google/gemini-2.5-flash"
        ])
        let gptShare = snap.topModels?.first(where: { $0.model == "openai/gpt-4.1" })
        #expect(Int((gptShare?.percent ?? 0).rounded()) == 47, "3.20 / 6.80 ≈ 47%")
        #expect(gptShare?.rawUsage == 3.20)
    }

    // MARK: - Z.AI

    @Test("Z.AI golden — session/weekly/mcp + lite tier label")
    func zai_golden() throws {
        let parsed = try JSONDecoder().decode(
            ZAIEnvelope.self,
            from: Fixtures.data(Fixtures.zaiUsage200))
        let snap = parsed.toSnapshot(configTier: nil)

        #expect(snap.planLabel == "GLM Lite")
        #expect(snap.session?.label == "Session (5h)")
        #expect(Int((snap.session?.utilizationPercent ?? 0).rounded()) == 24)
        #expect(snap.weekly?.label == "Weekly")
        #expect(Int((snap.weekly?.utilizationPercent ?? 0).rounded()) == 16)
        #expect(snap.mcp?.label == "Web tools")
        #expect(Int((snap.mcp?.utilizationPercent ?? 0).rounded()) == 4)
        #expect(snap.mcp?.detail == "40 / 1000")
        // topModels aggregated from usageDetails (search-prime 20 + web-reader 15 + zread 5 = 40)
        #expect(snap.topModels?.map(\.model) == ["search-prime", "web-reader", "zread"])
        #expect(Int((snap.topModels?[0].percent ?? 0).rounded()) == 50) // 20/40
        #expect(Int((snap.topModels?[1].percent ?? 0).rounded()) == 38) // 15/40 ≈ 37.5
        #expect(Int((snap.topModels?[2].percent ?? 0).rounded()) == 13) //  5/40 ≈ 12.5
        #expect(snap.topModels?[0].rawUsage == 20)
    }

    // MARK: - Kimi

    @Test("Kimi golden — available/voucher/cash split balance")
    func kimi_golden() throws {
        let parsed = try JSONDecoder().decode(
            KimiBalanceResponse.self,
            from: Fixtures.data(Fixtures.kimiBalance200))
        let snap = parsed.toSnapshot()

        #expect(snap.planLabel == "Moonshot · Kimi")
        #expect(snap.availableUSD == 87.65)
        #expect(snap.voucherUSD == 30.00)
        #expect(snap.cashUSD == 57.65)
        #expect(snap.balance?.label == "Balance")
        #expect(snap.balance?.detail == "$87.65 available")
    }

    // MARK: - Gemini

    @Test("Gemini golden — models heartbeat + plan label")
    func gemini_golden() throws {
        let parsed = try JSONDecoder().decode(
            GeminiModelsResponse.self,
            from: Fixtures.data(Fixtures.geminiModels200))
        let snap = parsed.toSnapshot()

        #expect(snap.planLabel == "Google AI Studio")
        #expect(snap.modelCount == 3)
        #expect(snap.status?.label == "API Key")
        #expect(snap.status?.utilizationPercent == 0)
        #expect(snap.status?.detail == "3 models available")
    }

    @Test("Gemini golden — empty models list still produces a valid snapshot")
    func gemini_empty_models() throws {
        let parsed = try JSONDecoder().decode(
            GeminiModelsResponse.self,
            from: Fixtures.data(Fixtures.geminiModelsEmpty200))
        let snap = parsed.toSnapshot()
        #expect(snap.modelCount == 0)
        #expect(snap.status?.detail == "API key valid (no models visible)")
    }

    // MARK: - DeepSeek

    @Test("DeepSeek golden — USD preferred over CNY, balance + breakdown")
    func deepseek_golden() throws {
        let parsed = try JSONDecoder().decode(
            DeepSeekBalanceResponse.self,
            from: Fixtures.data(Fixtures.deepseekBalance200))
        let snap = parsed.toSnapshot()

        // Pinned values — touching the decoder must touch this list.
        #expect(snap.planLabel == "DeepSeek")
        #expect(snap.currency == "USD")
        #expect(snap.totalBalance == 110.00)
        #expect(snap.grantedBalance == 10.00)
        #expect(snap.toppedUpBalance == 100.00)
        #expect(snap.isAvailable == true)
        #expect(snap.balance?.label == "Balance")
        #expect(snap.balance?.utilizationPercent == 0)
        #expect(snap.balance?.detail == "$110.00 available")
    }

    // MARK: - xAI

    @Test("xAI golden — prepaid + monthly spend vs limit")
    func xai_golden() throws {
        let prepaid = try JSONDecoder().decode(
            XAIPrepaidBalanceResponse.self,
            from: Fixtures.data(Fixtures.xaiPrepaidBalance200))
        let preview = try JSONDecoder().decode(
            XAIInvoicePreviewResponse.self,
            from: Fixtures.data(Fixtures.xaiInvoicePreview200))
        let snap = XAICachedPayload(prepaid: prepaid, preview: preview).toSnapshot()

        #expect(snap.planLabel == "xAI")
        #expect(snap.prepaidUSD == 45.0)
        #expect(snap.spentUSD == 12.5)
        #expect(snap.spendingLimitUSD == 200.0)
        #expect(snap.prepaidUsedUSD == 5.0)
        #expect(snap.billingCycleLabel == "2026-07")
        #expect(snap.balance?.label == "Balance")
        #expect(snap.balance?.utilizationPercent == 0)
        #expect(snap.balance?.detail == "$45.00 available")
        #expect(snap.monthly?.label == "Monthly (2026-07)")
        #expect(abs((snap.monthly?.utilizationPercent ?? 0) - 6.25) < 0.01)
        #expect(snap.monthly?.detail == "$12.50 / $200.00")
    }

    // MARK: - Cross-snapshot invariants

    @Test("VendorSnapshot.maxUtilization equals the highest window")
    func maxUtilization_matches_highest_window() throws {
        let parsed = try JSONDecoder().decode(
            ZAIEnvelope.self,
            from: Fixtures.data(Fixtures.zaiUsage200))
        let snap = VendorSnapshot.zai(parsed.toSnapshot(configTier: nil))
        let highest = snap.windows.map(\.utilizationPercent).max() ?? 0
        #expect(snap.maxUtilization == highest)
    }

    @Test("VendorSnapshot Codable round-trip is byte-stable enough to compare")
    func snapshot_codable_round_trip_is_stable() throws {
        let parsed = try JSONDecoder().decode(
            AnthropicUsageResponse.self,
            from: Fixtures.data(Fixtures.anthropicUsage200))
        let original = VendorSnapshot.anthropic(parsed.toSnapshot(planLabel: "Claude Max 5x"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(original)
        let back = try JSONDecoder().decode(VendorSnapshot.self, from: first)
        let second = try encoder.encode(back)
        // Encoder is deterministic with .sortedKeys; bytes must match.
        #expect(first == second)
        // And structural equality holds.
        #expect(original == back)
    }
}
