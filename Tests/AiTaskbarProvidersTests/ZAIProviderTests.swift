import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("Z.AI provider", .serialized)
struct ZAIProviderTests {
    let tmpCacheDir: URL

    init() throws {
        StubURLProtocol.reset()
        tmpCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-zai-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCacheDir)
    }

    @Test("no Bearer prefix on Authorization header")
    func no_bearer_prefix_on_authorization() async throws {
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
        let provider = ZAIProvider(credentials: creds, cache: cache, http: http, configTier: "lite")
        _ = try await provider.fetchUsage(forceRefresh: true)

        let auth = StubURLProtocol.captured.first?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "zai-test-key", "Z.AI must receive raw key, never `Bearer ...`")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("parses envelope and classifies entries")
    func parses_envelope_and_classifies_entries() async throws {
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
        let provider = ZAIProvider(credentials: creds, cache: cache, http: http, configTier: nil)
        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case let .zai(snap) = outcome.snapshot else {
            Issue.record("expected zai snapshot")
            return
        }
        #expect(snap.planLabel == "GLM Lite")
        #expect(snap.session?.label == "Session")
        #expect(snap.weekly?.label == "Weekly")
        #expect(snap.mcp?.label == "MCP tools")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("decode failure on malformed body raises AppError.schema")
    func zai_decode_failure_throws_schema() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Data("not z.ai shape".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .zai, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_ZAI_DEC", inlineKey: "k", vendorName: "Z.AI")
        let provider = ZAIProvider(credentials: creds, cache: cache, http: http)
        do {
            _ = try await provider.fetchUsage(forceRefresh: true)
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .schema = err {} else {
                Issue.record("expected .schema, got \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("falls back to cache on HTTP failure")
    func falls_back_to_cache_on_http_failure() async throws {
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
        let provider = ZAIProvider(credentials: creds, cache: cache, http: http)
        _ = try await provider.fetchUsage(forceRefresh: true)
        try await Task.sleep(nanoseconds: 50_000_000)

        let outcome = try await provider.fetchUsage(forceRefresh: true)
        #expect(outcome.isStale, "second fetch should serve stale cache")
        guard case let .zai(snap) = outcome.snapshot else {
            Issue.record("expected zai snapshot")
            return
        }
        #expect(snap.session != nil)
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }
}
