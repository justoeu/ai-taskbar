import XCTest
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

final class ZAIProviderTests: XCTestCase {
    var tmpCacheDir: URL!

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        tmpCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-zai-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCacheDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    func test_no_bearer_prefix_on_authorization() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.zaiUsage200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .zai, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_ZAI",
            inlineKey: "zai-test-key",
            vendorName: "Z.AI"
        )
        let provider = ZAIProvider(creds: creds, cache: cache, http: http, configTier: "lite")
        _ = try await provider.fetchUsage(forceRefresh: true)

        let auth = StubURLProtocol.captured.first?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "zai-test-key",
                       "Z.AI must receive raw key, never `Bearer ...`")
    }

    func test_parses_envelope_and_classifies_entries() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.zaiUsage200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .zai, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_ZAI_2",
            inlineKey: "k",
            vendorName: "Z.AI"
        )
        let provider = ZAIProvider(creds: creds, cache: cache, http: http, configTier: nil)
        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case let .zai(snap) = outcome.snapshot else {
            return XCTFail("expected zai")
        }
        XCTAssertEqual(snap.planLabel, "GLM Lite")
        XCTAssertEqual(snap.session?.label, "Session")
        XCTAssertEqual(snap.weekly?.label, "Weekly")
        XCTAssertEqual(snap.mcp?.label, "MCP tools")
    }

    func test_falls_back_to_cache_on_http_failure() async throws {
        // First request succeeds, second returns 500.
        var callCount = 0
        StubURLProtocol.handler = { _ in
            callCount += 1
            if callCount == 1 {
                return .init(data: Fixtures.data(Fixtures.zaiUsage200))
            }
            return .init(status: 500, data: Data("server error".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .zai, baseDir: tmpCacheDir, ttl: 0.001)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_ZAI_3",
            inlineKey: "k",
            vendorName: "Z.AI"
        )
        let provider = ZAIProvider(creds: creds, cache: cache, http: http)
        _ = try await provider.fetchUsage(forceRefresh: true)
        Thread.sleep(forTimeInterval: 0.05)

        let outcome = try await provider.fetchUsage(forceRefresh: true)
        XCTAssertTrue(outcome.isStale, "second fetch should serve stale cache")
        guard case let .zai(snap) = outcome.snapshot else {
            return XCTFail("expected zai")
        }
        XCTAssertNotNil(snap.session)
    }
}
