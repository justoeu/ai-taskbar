import Testing
@testable import AiTaskbarProviders

@Suite("AnthropicProvider.credLabel mapping")
struct CredLabelTests {
    @Test("Max + 20x rate limit → Claude Max 20x")
    func max_20x() {
        let label = AnthropicProvider.credLabel(
            subscriptionType: "max", rateLimit: "max_20x")
        #expect(label == "Claude Max 20x")
    }

    @Test("Max + 5x rate limit → Claude Max 5x")
    func max_5x() {
        let label = AnthropicProvider.credLabel(
            subscriptionType: "max", rateLimit: "max_5x")
        #expect(label == "Claude Max 5x")
    }

    @Test("Max with unknown rate limit → bare Claude Max")
    func max_unknown_rate_limit() {
        let label = AnthropicProvider.credLabel(
            subscriptionType: "max", rateLimit: "weird")
        #expect(label == "Claude Max")
    }

    @Test("known tiers map to friendly names")
    func known_tiers() {
        #expect(AnthropicProvider.credLabel(
            subscriptionType: "pro", rateLimit: nil) == "Claude Pro")
        #expect(AnthropicProvider.credLabel(
            subscriptionType: "team", rateLimit: nil) == "Claude Team")
        #expect(AnthropicProvider.credLabel(
            subscriptionType: "enterprise", rateLimit: nil) == "Claude Enterprise")
    }

    @Test("case-insensitive tier matching")
    func case_insensitive_tier() {
        #expect(AnthropicProvider.credLabel(
            subscriptionType: "PRO", rateLimit: nil) == "Claude Pro")
    }

    @Test("unknown subscription string falls through with capitalization")
    func unknown_subscription_capitalized() {
        let label = AnthropicProvider.credLabel(
            subscriptionType: "research_preview", rateLimit: nil)
        // Swift's `String.capitalized` upper-cases each "word" (separated
        // by non-letters), so "research_preview" → "Research_Preview".
        #expect(label == "Claude Research_Preview")
    }

    @Test("nil + empty subscription returns nil")
    func nil_and_empty_subscription() {
        #expect(AnthropicProvider.credLabel(
            subscriptionType: nil, rateLimit: nil) == nil)
        #expect(AnthropicProvider.credLabel(
            subscriptionType: "", rateLimit: nil) == nil)
    }
}
