import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// Vendor JSON may carry any finite Double (1e300 is valid JSON). Nothing on
/// the decode -> snapshot path may feed such a value to a trapping `Int(_:)`,
/// and no utilization / share may leave the wire type outside the
/// `UtilizationPercent` bounds (B3-numeric: SEC-CER-003/005, DUP-ECO-005).
@Suite("Numeric conversion traps — vendor wire types")
struct NumericConversionTrapTests {
    @Test("Anthropic utilization 1e300 is clamped at the UsageWindow boundary")
    func anthropic_huge_utilization_is_clamped() throws {
        let json = #"{ "five_hour": { "utilization": 1e300 } }"#
        let parsed = try JSONDecoder().decode(AnthropicUsageResponse.self, from: Data(json.utf8))
        let snap = VendorSnapshot.anthropic(parsed.toSnapshot(planLabel: nil))
        #expect(snap.maxUtilization == 1000)
    }

    @Test("Z.AI unit/number 1e300 decode without trapping (dropped as nil)")
    func zai_huge_unit_and_number_are_dropped() throws {
        let json = #"{ "type": "TOKENS_LIMIT", "unit": 1e300, "number": -1e300, "percentage": 5 }"#
        let entry = try JSONDecoder().decode(ZAILimitEntry.self, from: Data(json.utf8))
        expectTrue(entry.unit == nil)
        expectTrue(entry.number == nil)
    }

    @Test("Z.AI in-range unit/number still decode (truncating, as before)")
    func zai_normal_unit_and_number_decode() throws {
        let json = #"{ "type": "TOKENS_LIMIT", "unit": 3, "number": 5.0 }"#
        let entry = try JSONDecoder().decode(ZAILimitEntry.self, from: Data(json.utf8))
        #expect(entry.unit == 3)
        #expect(entry.number == 5)
    }

    @Test("Z.AI overflowing per-model totals never yield a NaN share")
    func zai_overflowing_totals_yield_finite_shares() throws {
        let json = #"""
        { "code": 200, "success": true, "data": { "level": "lite", "limits": [
          { "type": "TIME_LIMIT", "percentage": 1, "usageDetails": [
            { "modelCode": "a", "usage": 1.7e308 },
            { "modelCode": "a", "usage": 1.7e308 },
            { "modelCode": "b", "usage": 1.0 } ] } ] } }
        """#
        let env = try JSONDecoder().decode(ZAIEnvelope.self, from: Data(json.utf8))
        let shares = env.toSnapshot(configTier: nil).topModels ?? []
        #expect(shares.count == 2)
        #expect(shares.allSatisfy { $0.percent.isFinite && $0.percent >= 0 && $0.percent <= 100 })
    }

    @Test("OpenRouter overflowing per-model totals never yield a NaN share")
    func openrouter_overflowing_totals_yield_finite_shares() throws {
        let credits = try JSONDecoder().decode(
            OpenRouterCreditsResponse.self, from: Fixtures.data(Fixtures.openrouterCredits200))
        let key = try JSONDecoder().decode(
            OpenRouterKeyResponse.self, from: Fixtures.data(Fixtures.openrouterKeyFreeTier200))
        let activityJSON = #"""
        { "data": [ { "model": "x", "usage": 1.7e308 }, { "model": "x", "usage": 1.7e308 },
                    { "model": "y", "usage": 2.0 } ] }
        """#
        let activity = try JSONDecoder().decode(
            OpenRouterActivityResponse.self, from: Data(activityJSON.utf8))
        let shares = OpenRouterCachedPayload(credits: credits, key: key, activity: activity)
            .toSnapshot().topModels ?? []
        #expect(shares.count == 2)
        #expect(shares.allSatisfy { $0.percent.isFinite && $0.percent >= 0 && $0.percent <= 100 })
    }

    @Test("OpenAI limit_window_seconds 1e300 falls back to the default span label")
    func openai_huge_window_seconds_uses_default_label() throws {
        let json = #"""
        { "plan_type": "plus", "rate_limit": {
            "primary_window": { "used_percent": 1, "limit_window_seconds": 1e300 },
            "secondary_window": { "used_percent": 1, "limit_window_seconds": 1e300 } } }
        """#
        let parsed = try JSONDecoder().decode(OpenAIUsageResponse.self, from: Data(json.utf8))
        let snap = parsed.toSnapshot(planLabel: nil, fallbackNow: Date(timeIntervalSince1970: 0))
        #expect(snap.primary?.label == "Session (5h)")
        #expect(snap.secondary?.label == "Weekly (7d)")
    }

    @Test("Antigravity remaining_fraction 1e300 is clamped like consumedFraction")
    func gemini_huge_remaining_fraction_is_clamped() throws {
        let json = #"""
        { "status": "SUCCESS", "command": { "name": "usage", "data": { "groups": [
          { "name": "Gemini Models", "buckets": [
            { "id": "gemini-5h", "window": "5h", "remaining_fraction": 1e300 } ] } ] } } }
        """#
        let parsed = try JSONDecoder().decode(AntigravityUsageResponse.self, from: Data(json.utf8))
        let window = parsed.toSnapshot().fiveHour
        #expect(window?.detail == "100% remaining")
    }
}
