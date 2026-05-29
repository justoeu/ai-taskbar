import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("Kimi (Moonshot) provider", .serialized)
struct KimiProviderTests {
    let tmpCacheDir: URL

    init() throws {
        StubURLProtocol.reset()
        tmpCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-kimi-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCacheDir)
    }

    @Test("parses split balance shape (available/voucher/cash)")
    func parses_split_balance_shape() throws {
        let parsed = try JSONDecoder().decode(
            KimiBalanceResponse.self,
            from: Fixtures.data(Fixtures.kimiBalance200)
        )
        let snap = parsed.toSnapshot()
        #expect(snap.availableUSD == 87.65)
        #expect(snap.voucherUSD == 30.00)
        #expect(snap.cashUSD == 57.65)
        #expect(snap.balance?.label == "Balance")
        #expect(snap.balance?.detail?.contains("87.65") == true)
        #expect(snap.planLabel == "Moonshot · Kimi")
    }

    @Test("parses legacy single-balance shape")
    func parses_legacy_balance_shape() throws {
        let parsed = try JSONDecoder().decode(
            KimiBalanceResponse.self,
            from: Fixtures.data(Fixtures.kimiBalanceLegacy200)
        )
        let snap = parsed.toSnapshot()
        // No split fields — `availableBalance` is nil but the legacy
        // `balance` field carries through.
        #expect(snap.availableUSD == 42.00)
        #expect(snap.voucherUSD == nil)
        #expect(snap.cashUSD == nil)
    }

    @Test("parses string-encoded numeric balance fields")
    func parses_string_encoded_numbers() throws {
        let parsed = try JSONDecoder().decode(
            KimiBalanceResponse.self,
            from: Fixtures.data(Fixtures.kimiBalanceStringNumbers200)
        )
        let snap = parsed.toSnapshot()
        #expect(snap.availableUSD == 21.50)
        #expect(snap.voucherUSD == 0)
        #expect(snap.cashUSD == 21.50)
    }

    @Test("uses Bearer prefix for Authorization")
    func uses_bearer_prefix() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.kimiBalance200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .kimi, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_KIMI",
            inlineKey: "sk-kimi-test",
            vendorName: "Kimi"
        )
        let provider = KimiProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://api.moonshot.ai/v1")!
        )
        _ = try await provider.fetchUsage(forceRefresh: true)

        let auth = StubURLProtocol.captured.first?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer sk-kimi-test")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("base URL appends /users/me/balance")
    func base_url_appends_balance_path() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.kimiBalance200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .kimi, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_KIMI_2",
            inlineKey: "k",
            vendorName: "Kimi"
        )
        let provider = KimiProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://api.moonshot.ai/v1")!
        )
        _ = try await provider.fetchUsage(forceRefresh: true)

        let url = StubURLProtocol.captured.first?.url?.absoluteString ?? ""
        #expect(url.hasSuffix("/users/me/balance"), "got: \(url)")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("convenience init falls back to default URL when config invalid")
    func convenience_init_falls_back_to_default() throws {
        // Empty string will fail URL(string:); the convenience init must use
        // the default api.moonshot.ai URL instead of crashing.
        let cfg = KimiConfig(
            enabled: true,
            apiKeyEnv: "_UNSET",
            apiKey: "k",
            baseURL: "https://api.moonshot.ai/v1"
        )
        let provider = try KimiProvider(config: cfg, http: .init())
        #expect(provider.vendorId == .kimi)
    }
}
