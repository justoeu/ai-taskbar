import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("JWT decoder")
struct JWTTests {
    /// Header: {"alg":"none"} payload: {"exp": 1764201600, "...chatgpt_plan_type": "pro"}
    /// Hand-crafted token below.
    @Test("decode payload extracts known claims")
    func decode_payload_extracts_known_claims() throws {
        let header  = Data("{\"alg\":\"none\"}".utf8).base64URL()
        let payload = Data(
            #"{"exp":1764201600,"https://api.openai.com/auth.chatgpt_plan_type":"pro"}"#.utf8
        ).base64URL()
        let token = "\(header).\(payload)."
        let payload_value = JWT.decodePayload(token)
        // Top-level shape must be an object for claim lookup to make sense.
        guard case .object(let dict)? = payload_value else {
            Issue.record("expected .object payload, got \(String(describing: payload_value))")
            return
        }
        #expect(dict["https://api.openai.com/auth.chatgpt_plan_type"] == .string("pro"))
        #expect(JWT.expiry(token)?.timeIntervalSince1970 == 1764201600)
    }

    @Test("expiry returns nil on malformed token")
    func expiry_returns_nil_on_malformed_token() {
        #expect(JWT.expiry("not.a.jwt") == nil)
        #expect(JWT.expiry("") == nil)
        #expect(JWT.expiry("only-one-segment") == nil)
    }

    @Test("decodePayload returns nil when payload is not JSON")
    func decode_payload_returns_nil_on_non_json_payload() {
        let header = Data("{\"alg\":\"none\"}".utf8).base64URL()
        let badPayload = Data("not-json".utf8).base64URL()
        let token = "\(header).\(badPayload)."
        #expect(JWT.decodePayload(token) == nil)
    }

    @Test("claim<T> returns typed value when present")
    func typed_claim_returns_value() {
        let header = Data("{\"alg\":\"none\"}".utf8).base64URL()
        let payload = Data(#"{"sub":"user-123","aud":42}"#.utf8).base64URL()
        let token = "\(header).\(payload)."
        #expect(JWT.claim(token, key: "sub", as: String.self) == "user-123")
        #expect(JWT.claim(token, key: "aud", as: Int.self) == 42)
        #expect(JWT.claim(token, key: "missing", as: String.self) == nil)
    }
}

private extension Data {
    func base64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
