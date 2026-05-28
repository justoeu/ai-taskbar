import XCTest
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// Parse-level coverage for the Anthropic wire response. End-to-end provider
/// tests would need a protocol-based seam over the keychain reader; we test
/// the keychain reader separately and assume that boundary.
final class AnthropicProviderTests: XCTestCase {

    func test_parse_anthropic_usage_response() throws {
        let parsed = try JSONDecoder().decode(
            AnthropicUsageResponse.self,
            from: Fixtures.data(Fixtures.anthropicUsage200)
        )
        let snap = parsed.toSnapshot(planLabel: "Claude Max 5x")
        XCTAssertEqual(snap.session?.label, "Session (5h)")
        XCTAssertEqual(Int((snap.session?.utilizationPercent ?? 0).rounded()), 47)
        XCTAssertEqual(snap.weekly?.label, "Weekly (7d)")
        XCTAssertEqual(snap.extraUsageUSD, 2.45)
    }

    func test_anthropic_credentials_accepts_int_or_float_expires_at() throws {
        let asInt = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1764201600000}}"#
        let asFloat = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1764201600000.0}}"#
        let dec = JSONDecoder()
        let f1 = try dec.decode(AnthropicCredentialsFile.self, from: Data(asInt.utf8))
        let f2 = try dec.decode(AnthropicCredentialsFile.self, from: Data(asFloat.utf8))
        XCTAssertEqual(f1.claudeAiOauth.expiresAtMs, 1_764_201_600_000)
        XCTAssertEqual(f2.claudeAiOauth.expiresAtMs, 1_764_201_600_000)
    }

    func test_anthropic_oauth_parses_three_error_body_shapes() throws {
        let a = AnthropicOAuth.parseErrorBody(Data(#"{"error_description":"bad rt"}"#.utf8))
        let b = AnthropicOAuth.parseErrorBody(Data(#"{"error":{"message":"nope"}}"#.utf8))
        let c = AnthropicOAuth.parseErrorBody(Data(#"{"error":"plain"}"#.utf8))
        XCTAssertEqual(a, "bad rt")
        XCTAssertEqual(b, "nope")
        XCTAssertEqual(c, "plain")
    }
}
