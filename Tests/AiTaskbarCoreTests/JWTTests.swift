import XCTest
@testable import AiTaskbarCore

final class JWTTests: XCTestCase {
    /// Header: {"alg":"none"} payload: {"exp": 1764201600, "https://api.openai.com/auth.chatgpt_plan_type": "pro"}
    /// Hand-crafted token below.
    func test_decode_payload_extracts_known_claims() throws {
        let header  = Data("{\"alg\":\"none\"}".utf8).base64URL()
        let payload = Data(
            #"{"exp":1764201600,"https://api.openai.com/auth.chatgpt_plan_type":"pro"}"#.utf8
        ).base64URL()
        let token = "\(header).\(payload)."
        let dict = JWT.decodePayload(token)
        XCTAssertEqual(dict?["https://api.openai.com/auth.chatgpt_plan_type"] as? String, "pro")
        let exp = JWT.expiry(token)
        XCTAssertEqual(exp?.timeIntervalSince1970, 1764201600)
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
