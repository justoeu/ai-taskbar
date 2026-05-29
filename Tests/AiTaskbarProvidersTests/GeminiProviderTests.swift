import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("Gemini (Google AI) provider", .serialized)
struct GeminiProviderTests {
    let tmpCacheDir: URL

    init() throws {
        StubURLProtocol.reset()
        tmpCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-gemini-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCacheDir)
    }

    @Test("decodes models list and counts entries")
    func decodes_models_list() throws {
        let parsed = try JSONDecoder().decode(
            GeminiModelsResponse.self,
            from: Fixtures.data(Fixtures.geminiModels200)
        )
        let snap = parsed.toSnapshot()
        #expect(snap.modelCount == 3)
        #expect(snap.planLabel == "Google AI Studio")
        #expect(snap.status?.label == "API Key")
        #expect(snap.status?.detail == "3 models available")
    }

    @Test("empty list still produces a valid heartbeat")
    func empty_list_branch() throws {
        let parsed = try JSONDecoder().decode(
            GeminiModelsResponse.self,
            from: Fixtures.data(Fixtures.geminiModelsEmpty200)
        )
        let snap = parsed.toSnapshot()
        #expect(snap.modelCount == 0)
        #expect(snap.status?.detail == "API key valid (no models visible)")
    }

    @Test("uses x-goog-api-key header, not Bearer or query param")
    func uses_x_goog_api_key_header() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.geminiModels200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .gemini, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_GEMINI",
            inlineKey: "AIzaTestKey",
            vendorName: "Gemini"
        )
        let provider = GeminiProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        )
        _ = try await provider.fetchUsage(forceRefresh: true)

        let req = StubURLProtocol.captured.first
        #expect(req?.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaTestKey")
        // Authorization MUST NOT carry a Bearer prefix (this isn't Bearer auth).
        #expect(req?.value(forHTTPHeaderField: "Authorization") == nil)
        // Query string MUST NOT carry the key (header form keeps it out of logs).
        #expect((req?.url?.query ?? "").contains("key=") == false)
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("base URL appends /models")
    func base_url_appends_models_path() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.geminiModels200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .gemini, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_GEMINI_2",
            inlineKey: "k",
            vendorName: "Gemini"
        )
        let provider = GeminiProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        )
        _ = try await provider.fetchUsage(forceRefresh: true)

        let url = StubURLProtocol.captured.first?.url?.absoluteString ?? ""
        #expect(url.hasSuffix("/v1beta/models"), "got: \(url)")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("convenience init produces a valid provider")
    func convenience_init_smoke() throws {
        let cfg = GeminiConfig(
            enabled: true,
            apiKeyEnv: "_UNSET",
            apiKey: "k",
            baseURL: "https://generativelanguage.googleapis.com/v1beta"
        )
        let provider = try GeminiProvider(config: cfg, http: .init())
        #expect(provider.vendorId == .gemini)
    }
}
