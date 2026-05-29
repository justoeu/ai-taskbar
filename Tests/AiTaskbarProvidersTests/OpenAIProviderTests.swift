import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("OpenAI wire types")
struct OpenAIProviderTests {
    @Test("parse openai usage response")
    func parse_openai_usage_response() throws {
        let parsed = try JSONDecoder().decode(
            OpenAIUsageResponse.self,
            from: Fixtures.data(Fixtures.openaiUsage200)
        )
        let snap = parsed.toSnapshot(planLabel: "ChatGPT Plus",
                                     fallbackNow: Date(timeIntervalSince1970: 1_764_000_000))
        #expect(snap.primary?.label == "Session (5h)")
        #expect(Int((snap.primary?.utilizationPercent ?? 0).rounded()) == 33)
        #expect(snap.secondary?.label == "Weekly (7d)")
        #expect(snap.creditsUSD == 4.20)
        #expect(snap.messageCountRange == "≈ 5–10 local msgs left")
    }

    @Test("openai stripPII removes user_id account_id email")
    func stripPII_removes_pii_fields() throws {
        let raw = Data(#"""
        {"user_id":"u-1","account_id":"a-1","email":"x@y.z","primary":{"used":1,"total":10}}
        """#.utf8)
        let stripped = try OpenAIProvider.stripPII(from: raw)
        let json = try JSONSerialization.jsonObject(with: stripped) as? [String: Any]
        #expect(json?["user_id"] == nil)
        #expect(json?["account_id"] == nil)
        #expect(json?["email"] == nil)
        #expect((json?["primary"] as? [String: Any])?["used"] as? Int == 1)
    }

    @Test("openai computePlanLabel parses JWT claim")
    func computePlanLabel_parses_jwt() {
        let header = Data("{\"alg\":\"none\"}".utf8).base64URL()
        let payload = Data(#"{"https://api.openai.com/auth.chatgpt_plan_type":"pro"}"#.utf8).base64URL()
        let token = "\(header).\(payload)."
        #expect(OpenAIProvider.computePlanLabel(from: token) == "ChatGPT Pro")
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
