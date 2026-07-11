import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("Anthropic wire types and OAuth error parsing")
struct AnthropicProviderTests {
    @Test("parse anthropic usage response")
    func parse_anthropic_usage_response() throws {
        let parsed = try JSONDecoder().decode(
            AnthropicUsageResponse.self,
            from: Fixtures.data(Fixtures.anthropicUsage200)
        )
        let snap = parsed.toSnapshot(planLabel: "Claude Max 5x")
        #expect(snap.session?.label == "Session (5h)")
        #expect(Int((snap.session?.utilizationPercent ?? 0).rounded()) == 47)
        #expect(snap.weekly?.label == "Weekly (7d)")
        #expect(snap.scoped.first?.label == "Fable (7d)")
        #expect(snap.credits?.detail == "$2.45 / $20.00")
    }

    @Test("anthropic credentials accept int or float expires_at")
    func anthropic_credentials_accept_int_or_float_expires_at() throws {
        let asInt = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1764201600000}}"#
        let asFloat = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1764201600000.0}}"#
        let dec = JSONDecoder()
        let f1 = try dec.decode(AnthropicCredentialsFile.self, from: Data(asInt.utf8))
        let f2 = try dec.decode(AnthropicCredentialsFile.self, from: Data(asFloat.utf8))
        #expect(f1.claudeAiOauth.expiresAtMs == 1_764_201_600_000)
        #expect(f2.claudeAiOauth.expiresAtMs == 1_764_201_600_000)
    }

    @Test("anthropic OAuth parses three error body shapes")
    func anthropic_oauth_parses_three_error_body_shapes() throws {
        let a = AnthropicOAuth.parseErrorBody(Data(#"{"error_description":"bad rt"}"#.utf8))
        let b = AnthropicOAuth.parseErrorBody(Data(#"{"error":{"message":"nope"}}"#.utf8))
        let c = AnthropicOAuth.parseErrorBody(Data(#"{"error":"plain"}"#.utf8))
        #expect(a == "bad rt")
        #expect(b == "nope")
        #expect(c == "plain")
    }

    @Test("anthropic OAuth falls through on unknown error shape")
    func anthropic_oauth_falls_through_on_unknown_error_shape() {
        let raw = Data(#"{"weird":"shape"}"#.utf8)
        let parsed = AnthropicOAuth.parseErrorBody(raw)
        #expect(parsed == nil)
    }
}
