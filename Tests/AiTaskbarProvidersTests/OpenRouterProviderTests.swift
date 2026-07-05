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
            let path = req.url?.path ?? ""
            if path.contains("credits") {
                return .init(data: Fixtures.data(Fixtures.openrouterCredits200))
            }
            if path.contains("activity") {
                return .init(data: Fixtures.data(Fixtures.openrouterActivity200))
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
        #expect(snap.topModels?.map(\.model) == ["openai/gpt-4.1", "anthropic/claude-sonnet-4.6", "google/gemini-2.5-flash"])
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("uses bearer prefix for Authorization")
    func uses_bearer_prefix_for_authorization() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.contains("credits") {
                return .init(data: Fixtures.data(Fixtures.openrouterCredits200))
            }
            if path.contains("activity") {
                return .init(data: Fixtures.data(Fixtures.openrouterActivity200))
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

    @Test("activity 403 is silently ignored")
    func activity_403_ignored() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.contains("activity") {
                return .init(status: 403, data: Data())
            }
            if path.contains("credits") {
                return .init(data: Fixtures.data(Fixtures.openrouterCredits200))
            }
            return .init(data: Fixtures.data(Fixtures.openrouterKey200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .openrouter, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_OR_403",
            inlineKey: "sk-or-test",
            vendorName: "OpenRouter"
        )
        let provider = OpenRouterProvider(credentials: creds, cache: cache, http: http)

        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case let .openrouter(snap) = outcome.snapshot else {
            Issue.record("expected openrouter snapshot")
            return
        }
        #expect(snap.topModels == nil, "topModels should be nil when activity returns 403")
        #expect(snap.planLabel == "OpenRouter: primary")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("key response with periodic usage populates daily/weekly/monthly")
    func periodic_usage_windows() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.contains("credits") {
                return .init(data: Fixtures.data(Fixtures.openrouterCredits200))
            }
            if path.contains("activity") {
                return .init(status: 403, data: Data())
            }
            return .init(data: Fixtures.data(Fixtures.openrouterKeyWithPeriods200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .openrouter, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_OR_PD",
            inlineKey: "sk-or-test",
            vendorName: "OpenRouter"
        )
        let provider = OpenRouterProvider(credentials: creds, cache: cache, http: http)

        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case let .openrouter(snap) = outcome.snapshot else {
            Issue.record("expected openrouter snapshot")
            return
        }
        // usage_daily=2.50 / limit=50 → 5%
        #expect(Int((snap.daily?.utilizationPercent ?? 0).rounded()) == 5)
        // usage_weekly=18.00 / limit=50 → 36%
        #expect(Int((snap.weekly?.utilizationPercent ?? 0).rounded()) == 36)
        // usage_monthly=45.00 / limit=50 → 90%
        #expect(Int((snap.monthly?.utilizationPercent ?? 0).rounded()) == 90)
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }
}
