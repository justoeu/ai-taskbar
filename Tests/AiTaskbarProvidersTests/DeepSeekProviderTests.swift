import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("DeepSeek provider", .serialized)
struct DeepSeekProviderTests {
    let tmpCacheDir: URL

    init() throws {
        StubURLProtocol.reset()
        tmpCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-deepseek-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCacheDir)
    }

    @Test("uses Bearer prefix on Authorization header")
    func uses_bearer_prefix() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.deepseekBalance200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .deepseek, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_DEEPSEEK",
            inlineKey: "sk-deepseek-test",
            vendorName: "DeepSeek"
        )
        let provider = DeepSeekProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://api.deepseek.com")!
        )
        _ = try await provider.fetchUsage(forceRefresh: true)

        // Filter by the DeepSeek balance URL: StubURLProtocol.captured is
        // process-wide static, so when validate's coverage step runs without
        // --no-parallel a concurrent Kimi suite (hits /users/me/balance with a
        // different inline key) can land first in the shared array. Selecting
        // the /user/balance request makes this deterministic.
        let req = StubURLProtocol.captured.first {
            $0.url?.absoluteString.hasSuffix("/user/balance") == true
        }
        let auth = req?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer sk-deepseek-test", "DeepSeek must receive `Bearer ...`")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("base URL appends /user/balance")
    func base_url_appends_balance_path() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.deepseekBalance200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .deepseek, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_DEEPSEEK_2",
            inlineKey: "k",
            vendorName: "DeepSeek"
        )
        let provider = DeepSeekProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://api.deepseek.com")!
        )
        _ = try await provider.fetchUsage(forceRefresh: true)

        // Same cross-suite isolation as the bearer test: pick the DeepSeek
        // request by URL suffix.
        let url = StubURLProtocol.captured
            .first { $0.url?.absoluteString.hasSuffix("/user/balance") == true }?
            .url?.absoluteString ?? ""
        #expect(url.hasSuffix("/user/balance"), "got: \(url)")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("parses canonical balance and prefers USD over CNY")
    func parses_canonical_balance_usd_preference() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.deepseekBalance200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .deepseek, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_DEEPSEEK_3",
            inlineKey: "k",
            vendorName: "DeepSeek"
        )
        let provider = DeepSeekProvider(
            credentials: creds, cache: cache, http: http,
            baseURL: URL(string: "https://api.deepseek.com")!
        )
        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case let .deepseek(snap) = outcome.snapshot else {
            Issue.record("expected deepseek snapshot")
            return
        }
        #expect(snap.currency == "USD")
        #expect(snap.totalBalance == 110.00)
        #expect(snap.grantedBalance == 10.00)
        #expect(snap.toppedUpBalance == 100.00)
        #expect(snap.isAvailable == true)
        #expect(snap.balance?.detail == "$110.00 available")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("falls back to CNY when no USD entry present")
    func parses_cny_fallback() throws {
        let parsed = try JSONDecoder().decode(
            DeepSeekBalanceResponse.self,
            from: Fixtures.data(Fixtures.deepseekBalanceCNYOnly200))
        let snap = parsed.toSnapshot()
        #expect(snap.currency == "CNY")
        #expect(snap.totalBalance == 500.00)
        #expect(snap.balance?.detail == "¥500.00 available")
    }

    @Test("tolerates numeric (non-string) balance values")
    func parses_numeric_values() throws {
        let parsed = try JSONDecoder().decode(
            DeepSeekBalanceResponse.self,
            from: Fixtures.data(Fixtures.deepseekBalanceNumbers200))
        let snap = parsed.toSnapshot()
        #expect(snap.totalBalance == 42.5)
        #expect(snap.grantedBalance == 2.5)
        #expect(snap.toppedUpBalance == 40)
    }

    @Test("insufficient flag with no balance_infos does not crash")
    func parses_insufficient_no_infos() throws {
        let parsed = try JSONDecoder().decode(
            DeepSeekBalanceResponse.self,
            from: Fixtures.data(Fixtures.deepseekBalanceInsufficient200))
        let snap = parsed.toSnapshot()
        #expect(snap.isAvailable == false)
        #expect(snap.totalBalance == 0)
        #expect(snap.currency == nil)
    }

    @Test("decode failure on malformed body raises AppError.schema")
    func deepseek_decode_failure_throws_schema() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Data("not deepseek shape".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .deepseek, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_DEEPSEEK_DEC", inlineKey: "k", vendorName: "DeepSeek")
        let provider = DeepSeekProvider(
            credentials: creds, cache: cache, http: http,
            baseURL: URL(string: "https://api.deepseek.com")!)
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
                return .init(data: Fixtures.data(Fixtures.deepseekBalance200))
            }
            return .init(status: 500, data: Data("server error".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .deepseek, baseDir: tmpCacheDir, ttl: 0.001)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_DEEPSEEK_4",
            inlineKey: "k",
            vendorName: "DeepSeek"
        )
        let provider = DeepSeekProvider(
            credentials: creds, cache: cache, http: http,
            baseURL: URL(string: "https://api.deepseek.com")!)
        _ = try await provider.fetchUsage(forceRefresh: true)
        try await Task.sleep(nanoseconds: 50_000_000)

        let outcome = try await provider.fetchUsage(forceRefresh: true)
        #expect(outcome.isStale, "second fetch should serve stale cache")
        guard case let .deepseek(snap) = outcome.snapshot else {
            Issue.record("expected deepseek snapshot")
            return
        }
        #expect(snap.totalBalance == 110.00)
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }
}
