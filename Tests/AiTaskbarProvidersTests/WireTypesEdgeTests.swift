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
          "code": 0, "msg": "ok",
          "data": {
            "level": "pro",
            "limits": [
              { "name": "Session", "unit": "TOKENS_LIMIT", "used": 50, "limit": 100,
                "used_percent": 50.0, "window": "session" }
            ]
          }
        }
        """#
        let parsed = try JSONDecoder().decode(ZAIEnvelope.self, from: Data(body.utf8))
        let snap = parsed.toSnapshot(configTier: nil)
        #expect(snap.session != nil)
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

    @Test("Z.AI envelope without window field uses default classification")
    func zai_no_window_field_classifies_by_unit() throws {
        let body = #"""
        {
          "code": 0, "data": {
            "level": "lite",
            "limits": [
              { "name": "WindowlessSession", "unit": "TOKENS_LIMIT",
                "used": 1, "limit": 5, "used_percent": 20.0 },
              { "name": "MCP", "unit": "MCP_LIMIT",
                "used": 1, "limit": 10, "used_percent": 10.0 }
            ]
          }
        }
        """#
        let parsed = try JSONDecoder().decode(ZAIEnvelope.self, from: Data(body.utf8))
        let snap = parsed.toSnapshot(configTier: nil)
        // First TOKENS_LIMIT without window classification becomes session.
        #expect(snap.session != nil)
        #expect(snap.mcp != nil)
    }

    @Test("Z.AI envelope with MCP only — mcp window populated")
    func zai_mcp_only_branch() throws {
        let body = #"""
        {
          "code": 0, "data": {
            "level": "lite",
            "limits": [
              { "name": "MCP tools", "unit": "MCP_LIMIT", "used": 3, "limit": 50, "used_percent": 6.0 }
            ]
          }
        }
        """#
        let parsed = try JSONDecoder().decode(ZAIEnvelope.self, from: Data(body.utf8))
        let snap = parsed.toSnapshot(configTier: nil)
        #expect(snap.mcp != nil)
        #expect(snap.session == nil)
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
