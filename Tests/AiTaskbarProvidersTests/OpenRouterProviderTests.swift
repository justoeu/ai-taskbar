import XCTest
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

final class OpenRouterProviderTests: XCTestCase {
    var tmpCacheDir: URL!

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        tmpCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-or-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCacheDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    func test_combined_response_parses_to_snapshot() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.path.contains("credits") == true {
                return .init(data: Fixtures.data(Fixtures.openrouterCredits200))
            } else {
                return .init(data: Fixtures.data(Fixtures.openrouterKey200))
            }
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .openrouter, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_FOR_TEST_OR",
            inlineKey: "sk-or-test",
            vendorName: "OpenRouter"
        )
        let provider = OpenRouterProvider(creds: creds, cache: cache, http: http)

        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case let .openrouter(snap) = outcome.snapshot else {
            return XCTFail("expected openrouter snapshot")
        }
        XCTAssertEqual(snap.planLabel, "OpenRouter: primary")
        XCTAssertEqual(Int((snap.balance?.utilizationPercent ?? 0).rounded()), 25)
        XCTAssertEqual(Int((snap.monthly?.utilizationPercent ?? 0).rounded()), 25)
    }

    func test_uses_bearer_prefix_for_authorization() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.path.contains("credits") == true {
                return .init(data: Fixtures.data(Fixtures.openrouterCredits200))
            }
            return .init(data: Fixtures.data(Fixtures.openrouterKey200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .openrouter, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_OR_2",
            inlineKey: "sk-or-test",
            vendorName: "OpenRouter"
        )
        let provider = OpenRouterProvider(creds: creds, cache: cache, http: http)
        _ = try await provider.fetchUsage(forceRefresh: true)

        let auths = StubURLProtocol.captured.compactMap {
            $0.value(forHTTPHeaderField: "Authorization")
        }
        XCTAssertTrue(auths.allSatisfy { $0 == "Bearer sk-or-test" },
                      "got: \(auths)")
    }
}
