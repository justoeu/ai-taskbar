import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("Wire-type edge cases (rare but real shapes)")
struct WireTypesEdgeTests {
    @Test("OpenAI balance decoded as plain Int")
    func openai_balance_int_branch() throws {
        let parsed = try JSONDecoder().decode(
            OpenAIUsageResponse.self,
            from: Fixtures.data(Fixtures.openaiUsageBalanceAsInt200))
        let snap = parsed.toSnapshot(planLabel: nil,
                                     fallbackNow: Date(timeIntervalSince1970: 0))
        #expect(snap.creditsUSD == 7)
        // Approx cloud messages branch (cloud → "cloud msgs left").
        #expect(snap.messageCountRange?.contains("cloud") == true)
    }

    @Test("OpenRouter free tier uses fallback planLabel")
    func openrouter_free_tier_branch() throws {
        let credits = try JSONDecoder().decode(
            OpenRouterCreditsResponse.self,
            from: Fixtures.data(Fixtures.openrouterCredits200))
        let key = try JSONDecoder().decode(
            OpenRouterKeyResponse.self,
            from: Fixtures.data(Fixtures.openrouterKeyFreeTier200))
        let combined = OpenRouterCombined(credits: credits, key: key)
        let snap = combined.toSnapshot()
        // free_tier → planLabel "OpenRouter Free Tier"
        #expect(snap.planLabel == "OpenRouter Free Tier")
    }

    @Test("Z.AI session-only envelope yields the session window")
    func zai_session_only() throws {
        let body = #"""
        {
          "code": 200, "msg": "ok", "success": true,
          "data": {
            "level": "pro",
            "limits": [
              { "type": "TOKENS_LIMIT", "unit": 3, "number": 5,
                "percentage": 50, "nextResetTime": 1781759602799 }
            ]
          }
        }
        """#
        let parsed = try JSONDecoder().decode(ZAIEnvelope.self, from: Data(body.utf8))
        let snap = parsed.toSnapshot(configTier: nil)
        #expect(snap.session != nil)
        #expect(snap.session?.label == "Session (5h)")
        #expect(snap.session?.utilizationPercent == 50)
        #expect(snap.weekly == nil)
        #expect(snap.mcp == nil)
        #expect(snap.planLabel == "GLM Pro")
    }

    @Test("Z.AI configTier overrides snapshot.planLabel")
    func zai_config_tier_wins() throws {
        let body = #"""
        { "code": 0, "data": { "limits": [] } }
        """#
        let parsed = try JSONDecoder().decode(ZAIEnvelope.self, from: Data(body.utf8))
        let snap = parsed.toSnapshot(configTier: "max")
        #expect(snap.planLabel == "GLM Max")
    }

    @Test("OpenRouter no limit + no total → balance unknown branch")
    func openrouter_no_limit_no_total_branch() throws {
        let creditsBody = #"{"data": {"total_usage": 1.50}}"#
        let keyBody = #"{"data": {"label": "primary", "usage": 1.50}}"#
        let credits = try JSONDecoder().decode(
            OpenRouterCreditsResponse.self, from: Data(creditsBody.utf8))
        let key = try JSONDecoder().decode(
            OpenRouterKeyResponse.self, from: Data(keyBody.utf8))
        let combined = OpenRouterCombined(credits: credits, key: key)
        let snap = combined.toSnapshot()
        // planLabel fallback when no label info → "OpenRouter"
        #expect(snap.planLabel == "OpenRouter: primary")
    }

    @Test("OpenAI credits balance with neither string nor int → nil")
    func openai_credits_no_balance_branch() throws {
        let body = #"""
        {
          "user_id": "u",
          "rate_limit": {
            "primary_window": { "used_percent": 5.0, "limit_window_seconds": 18000 }
          },
          "credits": { "has_credits": false }
        }
        """#
        let parsed = try JSONDecoder().decode(
            OpenAIUsageResponse.self, from: Data(body.utf8))
        let snap = parsed.toSnapshot(planLabel: nil,
                                     fallbackNow: Date(timeIntervalSince1970: 0))
        #expect(snap.creditsUSD == nil)
    }

    @Test("Z.AI entry without a known unit code falls back to a plain Session label")
    func zai_unknown_unit_falls_back() throws {
        let body = #"""
        {
          "code": 200, "data": {
            "level": "lite",
            "limits": [
              { "type": "TOKENS_LIMIT", "unit": 99, "number": 2,
                "percentage": 20, "nextResetTime": 1781759602799 },
              { "type": "TIME_LIMIT", "unit": 5, "number": 1, "usage": 10,
                "currentValue": 1, "percentage": 10, "nextResetTime": 1784333321994 }
            ]
          }
        }
        """#
        let parsed = try JSONDecoder().decode(ZAIEnvelope.self, from: Data(body.utf8))
        let snap = parsed.toSnapshot(configTier: nil)
        // TOKENS_LIMIT → session; unknown unit code → "Session" without suffix.
        #expect(snap.session?.label == "Session")
        #expect(snap.session?.utilizationPercent == 20)
        // TIME_LIMIT → web-tool (mcp) slot.
        #expect(snap.mcp?.label == "Web tools")
        #expect(snap.mcp?.detail == "1 / 10")
    }

    @Test("Z.AI envelope with TIME_LIMIT only — mcp window populated")
    func zai_time_limit_only_branch() throws {
        let body = #"""
        {
          "code": 200, "data": {
            "level": "lite",
            "limits": [
              { "type": "TIME_LIMIT", "unit": 5, "number": 1, "usage": 50,
                "currentValue": 3, "remaining": 47, "percentage": 6,
                "nextResetTime": 1784333321994 }
            ]
          }
        }
        """#
        let parsed = try JSONDecoder().decode(ZAIEnvelope.self, from: Data(body.utf8))
        let snap = parsed.toSnapshot(configTier: nil)
        #expect(snap.mcp != nil)
        #expect(snap.mcp?.detail == "3 / 50")
        #expect(snap.session == nil)
        #expect(snap.weekly == nil)
    }

    @Test("KimiBalance toSnapshot when data is nil")
    func kimi_nil_data_branch() throws {
        let body = #"""
        { "code": 1, "status": false }
        """#
        let parsed = try JSONDecoder().decode(KimiBalanceResponse.self, from: Data(body.utf8))
        let snap = parsed.toSnapshot()
        #expect(snap.availableUSD == 0)
        #expect(snap.balance != nil)
    }
}
