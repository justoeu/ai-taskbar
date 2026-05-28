import XCTest
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

final class OpenAIProviderTests: XCTestCase {
    func test_parse_openai_usage_response() throws {
        let parsed = try JSONDecoder().decode(
            OpenAIUsageResponse.self,
            from: Fixtures.data(Fixtures.openaiUsage200)
        )
        let snap = parsed.toSnapshot(planLabel: "ChatGPT Plus",
                                     fallbackNow: Date(timeIntervalSince1970: 1_764_000_000))
        XCTAssertEqual(snap.primary?.label, "Session (5h)")
        XCTAssertEqual(Int((snap.primary?.utilizationPercent ?? 0).rounded()), 33)
        XCTAssertEqual(snap.secondary?.label, "Weekly (7d)")
        XCTAssertEqual(snap.creditsUSD, 4.20)
        XCTAssertEqual(snap.messageCountRange, "≈ 5–10 local msgs left")
    }
}
