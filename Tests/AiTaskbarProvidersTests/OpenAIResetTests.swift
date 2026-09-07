import Foundation
import Testing
import AiTaskbarCore
import AiTaskbarTesting
@testable import AiTaskbarProviders

@Suite("OpenAI earned resets")
struct OpenAIResetTests {
    @Test("reset credit summary survives the wire-to-snapshot contract")
    func reset_summary_golden() throws {
        let wire = try SharedCoders.decoder.decode(OpenAIUsageResponse.self,
            from: Fixtures.data(Fixtures.openaiUsageWithReset200))
        let snapshot = wire.toSnapshot(planLabel: nil)
        expectTrue(snapshot.availableResetCount == 2)
        expectTrue(snapshot.planLabel == "ChatGPT Pro")
        expectTrue(snapshot.creditsUSD == nil)
        expectTrue(snapshot.messageCountRange == nil)
        let primary = try #require(snapshot.primary)
        let secondary = try #require(snapshot.secondary)
        #expect(primary == UsageWindow(label: "Session (5h)", utilizationPercent: 91))
        #expect(secondary == UsageWindow(label: "Weekly (7d)", utilizationPercent: 25))
        expectTrue(snapshot.canOfferRateLimitReset)
    }

    @Test("reset action requires strictly over 90 percent and known positive availability",
          arguments: [89.0, 90.0, 90.1, 100.0])
    func reset_threshold(percent: Double) {
        let window = UsageWindow(label: "Session", utilizationPercent: percent)
        for count: Int? in [nil, -1, 0, 1] {
            let snapshot = OpenAISnapshot(primary: window, availableResetCount: count)
            expectTrue(snapshot.canOfferRateLimitReset == (percent > 90 && (count ?? 0) > 0))
        }
        let weekly = OpenAISnapshot(secondary: window, availableResetCount: 1)
        expectTrue(weekly.canOfferRateLimitReset == (percent > 90))
        expectFalse(OpenAISnapshot(availableResetCount: 1).canOfferRateLimitReset)
    }

    @Test("old payloads do not imply a reset is available")
    func absent_is_unknown() throws {
        let wire = try SharedCoders.decoder.decode(OpenAIUsageResponse.self,
            from: Fixtures.data(Fixtures.openaiUsage200))
        expectTrue(wire.toSnapshot(planLabel: nil).availableResetCount == nil)
        expectFalse(wire.toSnapshot(planLabel: nil).canOfferRateLimitReset)
    }

    @Test("malformed experimental reset metadata cannot hide ordinary usage",
          arguments: ["[]", "\"changed\"", "{}", "{\"available_count\":\"two\"}"])
    func malformed_summary(summary: String) throws {
        let json = "{\"rate_limit\":{\"primary_window\":{\"used_percent\":91}},\"rate_limit_reset_credits\":\(summary)}"
        let snapshot = try SharedCoders.decoder.decode(OpenAIUsageResponse.self, from: Data(json.utf8)).toSnapshot(planLabel: nil)
        expectTrue(snapshot.primary?.utilizationPercent == 91)
        expectTrue(snapshot.availableResetCount == nil)
        expectFalse(snapshot.canOfferRateLimitReset)
    }
}
