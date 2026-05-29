import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("OpenRouter provider", .serialized)
struct OpenRouterProviderTests {
    let tmpCacheDir: URL

    init() throws {
        StubURLProtocol.reset()
        tmpCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-or-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCacheDir)
    }

    @Test("combined response parses to snapshot")
    func combined_response_parses_to_snapshot() async throws {
        StubURLProtocol.handler = { req in
            if req.url?.path.contains("credits") == true {
                return .init(data: Fixtures.data(Fixtures.openrouterCredits200))
            }
            return .init(data: Fixtures.data(Fixtures.openrouterKey200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .openrouter, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_FOR_TEST_OR",
            inlineKey: "sk-or-test",
            vendorName: "OpenRouter"
        )
        let provider = OpenRouterProvider(credentials: creds, cache: cache, http: http)

        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case let .openrouter(snap) = outcome.snapshot else {
            Issue.record("expected openrouter snapshot")
            return
        }
        #expect(snap.planLabel == "OpenRouter: primary")
        #expect(Int((snap.balance?.utilizationPercent ?? 0).rounded()) == 25)
        #expect(Int((snap.monthly?.utilizationPercent ?? 0).rounded()) == 25)
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("uses bearer prefix for Authorization")
    func uses_bearer_prefix_for_authorization() async throws {
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
        let provider = OpenRouterProvider(credentials: creds, cache: cache, http: http)
        _ = try await provider.fetchUsage(forceRefresh: true)

        let auths = StubURLProtocol.captured.compactMap {
            $0.value(forHTTPHeaderField: "Authorization")
        }
        #expect(auths.allSatisfy { $0 == "Bearer sk-or-test" }, "got: \(auths)")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }
}
