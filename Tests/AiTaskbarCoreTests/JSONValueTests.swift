import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("JSONValue sum-of-shapes decoder")
struct JSONValueTests {
    @Test("decodes a heterogeneous object")
    func decodes_heterogeneous_object() throws {
        let json = #"""
        {
          "n": null,
          "b": true,
          "i": 42,
          "f": 3.14,
          "s": "hi",
          "arr": [1, "two", false],
          "obj": { "nested": "value" }
        }
        """#
        let decoded = try JSONDecoder().decode([String: JSONValue].self,
                                                from: Data(json.utf8))
        #expect(decoded["n"] == .null)
        #expect(decoded["b"] == .bool(true))
        #expect(decoded["i"] == .int(42))
        #expect(decoded["s"] == .string("hi"))
        // Float can match Int when it has no fractional part — JSON doesn't
        // distinguish. The decoder tries Int first, so 3.14 becomes .double.
        if case .double(let d) = decoded["f"] {
            #expect(d == 3.14)
        } else {
            Issue.record("expected .double, got \(decoded["f"] as Any)")
        }
        if case .array(let a) = decoded["arr"] {
            #expect(a.count == 3)
        } else {
            Issue.record("expected array")
        }
    }

    @Test("round-trip preserves the value")
    func round_trip_preserves_value() throws {
        let original: [String: JSONValue] = [
            "n": .null,
            "b": .bool(false),
            "i": .int(7),
            "d": .double(1.5),
            "s": .string("x"),
            "arr": .array([.int(1), .int(2)]),
            "obj": .object(["key": .string("v")]),
        ]
        let encoded = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
        #expect(back == original)
    }

    @Test("stringValue extracts strings, returns nil for non-strings")
    func string_value_helper() {
        #expect(JSONValue.string("hello").stringValue == "hello")
        #expect(JSONValue.int(1).stringValue == nil)
        #expect(JSONValue.null.stringValue == nil)
        #expect(JSONValue.bool(true).stringValue == nil)
        #expect(JSONValue.double(1.5).stringValue == nil)
    }

    @Test("integers round-trip with full int64 range")
    func integers_round_trip_int64() throws {
        let big: Int64 = 9_007_199_254_740_993  // > 2^53, loses precision in JS but not Swift
        let value = JSONValue.int(big)
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        if case .int(let i) = back {
            #expect(i == big)
        } else {
            Issue.record("expected .int")
        }
    }

    @Test("Equatable compares structurally")
    func equatable_compares_structurally() {
        let a: JSONValue = .object(["x": .int(1)])
        let b: JSONValue = .object(["x": .int(1)])
        let c: JSONValue = .object(["x": .int(2)])
        #expect(a == b)
        #expect(a != c)
    }
}

@Suite("CodexTokens + AnthropicCredentials wire shape")
struct CodexAndAnthropicCredentialsTests {
    @Test("CodexTokens snake_case round-trip")
    func codex_tokens_snake_case() throws {
        let json = #"""
        { "access_token": "a", "refresh_token": "r", "id_token": "i" }
        """#
        let t = try JSONDecoder().decode(CodexTokens.self, from: Data(json.utf8))
        #expect(t.accessToken == "a")
        #expect(t.refreshToken == "r")
        #expect(t.idToken == "i")
        let encoded = try JSONEncoder().encode(t)
        // re-decode succeeds — snake_case CodingKeys survive write
        let back = try JSONDecoder().decode(CodexTokens.self, from: encoded)
        #expect(back == t)
    }

    @Test("AnthropicCredentials computes expiresAt from milliseconds")
    func anthropic_creds_expires_at() {
        let creds = AnthropicCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAtMs: 1_700_000_000_000)
        // 1_700_000_000_000 ms = 1_700_000_000 s = Tue Nov 14 2023 22:13:20 UTC
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("isExpired respects buffer")
    func is_expired_respects_buffer() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // expires in 100 s; buffer 300 s → considered expired NOW.
        let about_to_expire = AnthropicCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAtMs: 1_700_000_100_000)
        #expect(about_to_expire.isExpired(buffer: 300, now: now))
        // expires in 600 s; buffer 300 s → still fresh.
        let well_fresh = AnthropicCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAtMs: 1_700_000_600_000)
        #expect(!well_fresh.isExpired(buffer: 300, now: now))
    }

    @Test("CodexAuth carries unknownTopLevel through")
    func codex_auth_preserves_unknown_top_level() {
        let extras: [String: JSONValue] = ["last_refresh": .string("x")]
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: "a", refreshToken: "r", idToken: "i"),
            accountId: "acc",
            unknownTopLevel: extras
        )
        #expect(auth.unknownTopLevel["last_refresh"] == .string("x"))
        #expect(auth.accountId == "acc")
    }
}
