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

    @Test("missing `models` key produces a schema-warning snapshot, not silent zero")
    func missing_models_key_surfaces_schema_warning() throws {
        // Simulates a future Google v1beta rename that drops the `models`
        // key entirely. Decoder still succeeds because the field is
        // Optional, but toSnapshot() should NOT pretend the API key is
        // valid-with-zero-models — that would mask the regression.
        let payload = Data(#"{"nextPageToken":"abc"}"#.utf8)
        let parsed = try JSONDecoder().decode(GeminiModelsResponse.self, from: payload)
        let snap = parsed.toSnapshot()
        #expect(snap.modelCount == 0)
        #expect(snap.status?.detail?.contains("Unexpected response shape") == true)
    }

    @Test("empty models list still claims 'API key valid (no models visible)'")
    func empty_list_branch_keeps_valid_phrasing() throws {
        // The empty-list case (key valid, no models granted to this user
        // yet) must NOT regress into the schema-warning branch.
        let payload = Data(#"{"models":[]}"#.utf8)
        let parsed = try JSONDecoder().decode(GeminiModelsResponse.self, from: payload)
        let snap = parsed.toSnapshot()
        #expect(snap.modelCount == 0)
        #expect(snap.status?.detail == "API key valid (no models visible)")
    }

    @Test("GeminiConfig.validate rejects URLs without /v1 path prefix")
    func validate_rejects_missing_api_version() {
        // Bare host: rejected.
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com") == nil)
        // Root path: rejected.
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/") == nil)
        // Non-/v1 path: rejected.
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/models") == nil)
        // Allowed shapes.
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/v1beta") != nil)
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/v1") != nil)
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/v1alpha") != nil)
    }
}
