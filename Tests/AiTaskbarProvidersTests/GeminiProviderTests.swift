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
        expectFalse((req?.url?.query ?? "").contains("key="))
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

    @Test("toSnapshot defensive backstop renders schema-warning detail when called with models == nil")
    func missing_models_key_surfaces_schema_warning() throws {
        // The production path now rejects this shape inside
        // `decodeSnapshot` (see `missing_models_field_throws_schema_error`
        // below). This test still pins `toSnapshot`'s defensive branch so
        // anyone calling it directly — bypassing the provider's decoder —
        // also gets the warning phrasing instead of a false-positive
        // "valid (no models visible)".
        let payload = Data(#"{"nextPageToken":"abc"}"#.utf8)
        let parsed = try JSONDecoder().decode(GeminiModelsResponse.self, from: payload)
        let snap = parsed.toSnapshot()
        #expect(snap.modelCount == 0)
        expectTrue(snap.status?.detail?.contains("Unexpected response shape") ?? false)
    }

    @Test("missing `models` field surfaces AppError.schema from the production decode path")
    func missing_models_field_throws_schema_error() async throws {
        // The whole point of the schema throw in decodeSnapshot is that
        // a future Google v1beta rename surfaces as a .failed vendor
        // state (red row + visible error) instead of a silently green
        // "no models visible" snapshot. CachedFetch lifts the throw into
        // markFailed + fallback; with no cached payload, fetchUsage
        // rethrows as AppError.schema.
        StubURLProtocol.handler = { _ in
            .init(data: Data(#"{"nextPageToken":"abc"}"#.utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .gemini, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_GEMINI_SCHEMA",
            inlineKey: "k",
            vendorName: "Gemini"
        )
        let provider = GeminiProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        )
        do {
            _ = try await provider.fetchUsage(forceRefresh: true)
            Issue.record("expected AppError.schema; got success")
        } catch let err as AppError {
            if case .schema(let msg) = err {
                #expect(msg.contains("missing `models`"))
            } else {
                Issue.record("expected AppError.schema, got \(err)")
            }
        }
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
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

    @Test("GeminiConfig.validate rejects URLs without an accepted API-version path")
    func validate_rejects_missing_api_version() {
        // Bare host / root path / non-versioned path: rejected.
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com") == nil)
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/") == nil)
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/models") == nil)
        // Strict-prefix matcher rejects typos that the previous
        // `hasPrefix("/v1")` accepted (these would 404 at runtime).
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/v1banana") == nil)
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/v1xxxxxx") == nil)
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/v123") == nil)
        // Allowed shapes (exact match or rooted subpath).
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/v1") != nil)
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/v1beta") != nil)
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/v1alpha") != nil)
        #expect(GeminiConfig.validate("https://generativelanguage.googleapis.com/v1beta/models") != nil)
    }

    // MARK: - Antigravity Integration Tests

    @Test("preferAntigravity uses Antigravity executor when installed")
    func antigravity_happy_path() async throws {
        let mock = MockAntigravityExecutor(
            installed: true,
            data: Fixtures.data(Fixtures.antigravityUsage200)
        )
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .gemini, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_GEMINI_AGY",
            inlineKey: nil,
            vendorName: "Gemini"
        )
        let provider = GeminiProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            antigravity: mock,
            preferAntigravity: true
        )
        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case .gemini(let s) = outcome.snapshot else {
            Issue.record("expected .gemini snapshot")
            return
        }
        expectTrue(s.isAntigravityActive)
        #expect(s.planLabel == "Antigravity")
        #expect(s.disclaimer != nil)
        #expect(s.fiveHour != nil)
        #expect(s.weekly != nil)
        #expect(s.thirdParty5Hour != nil)
        #expect(s.thirdPartyWeekly != nil)
        #expect(StubURLProtocol.captured.isEmpty)
        try? FileManager.default.removeItem(at: tmpCacheDir)
    }

    @Test("Antigravity unauthenticated error bubbles up as 401")
    func antigravity_unauthenticated_error() async throws {
        let mock = MockAntigravityExecutor(
            installed: true,
            error: AppError.http(status: 401, body: "Antigravity não autenticado. Execute 'agy' no Terminal.")
        )
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .gemini, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_GEMINI_AGY_UNAUTH",
            inlineKey: nil,
            vendorName: "Gemini"
        )
        let provider = GeminiProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            antigravity: mock,
            preferAntigravity: true
        )
        do {
            _ = try await provider.fetchUsage(forceRefresh: true)
            Issue.record("expected AppError.http(401)")
        } catch let err as AppError {
            expectTrue(err.isUnauthorized)
        }
        try? FileManager.default.removeItem(at: tmpCacheDir)
    }

    @Test("Antigravity falls back to HTTP models heartbeat when not installed but API key is present")
    func antigravity_fallback_when_not_installed() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.geminiModels200))
        }
        let mock = MockAntigravityExecutor(installed: false)
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .gemini, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_GEMINI_FALLBACK",
            inlineKey: "AIzaTestKey",
            vendorName: "Gemini"
        )
        let provider = GeminiProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            antigravity: mock,
            preferAntigravity: true
        )
        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case .gemini(let s) = outcome.snapshot else {
            Issue.record("expected .gemini snapshot")
            return
        }
        expectFalse(s.isAntigravityActive)
        #expect(s.modelCount == 3)
        #expect(s.disclaimer != nil)
        #expect(StubURLProtocol.captured.count == 1)
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("Antigravity throws disclaimer error when not installed and no API key is set")
    func antigravity_not_installed_no_api_key_throws_disclaimer() async throws {
        let mock = MockAntigravityExecutor(installed: false)
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .gemini, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_GEMINI_NONE",
            inlineKey: nil,
            vendorName: "Gemini"
        )
        let provider = GeminiProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            antigravity: mock,
            preferAntigravity: true
        )
        do {
            _ = try await provider.fetchUsage(forceRefresh: true)
            Issue.record("expected credentials error")
        } catch let err as AppError {
            if case .credentials(let msg) = err {
                expectTrue(msg.contains("Antigravity instalado e autenticado"))
            } else {
                Issue.record("expected credentials, got \(err)")
            }
        }
        try? FileManager.default.removeItem(at: tmpCacheDir)
    }

    @Test("preferAntigravity = false skips Antigravity even if installed")
    func prefer_antigravity_false_skips() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.geminiModels200))
        }
        let mock = MockAntigravityExecutor(
            installed: true,
            data: Fixtures.data(Fixtures.antigravityUsage200)
        )
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .gemini, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_GEMINI_NOPREFER",
            inlineKey: "AIzaTestKey",
            vendorName: "Gemini"
        )
        let provider = GeminiProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            antigravity: mock,
            preferAntigravity: false
        )
        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case .gemini(let s) = outcome.snapshot else {
            Issue.record("expected .gemini snapshot")
            return
        }
        expectFalse(s.isAntigravityActive)
        #expect(s.modelCount == 3)
        #expect(StubURLProtocol.captured.count == 1)
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    // MARK: - ProcessAntigravityExecutor Tests

    @Test("ProcessAntigravityExecutor resolves custom path and validates executable")
    func process_executor_custom_path() throws {
        let scriptDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-script-\(UUID().uuidString)")
        try Paths.ensureDir(scriptDir)
        let scriptPath = scriptDir.appendingPathComponent("fake_agy").path
        let scriptContent = "#!/bin/sh\necho 'hello'\n"
        try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        let customExec = ProcessAntigravityExecutor(customPath: scriptPath)
        #expect(customExec.resolvedExecutableURL?.path == scriptPath)
        expectTrue(customExec.isInstalled())

        try? FileManager.default.removeItem(at: scriptDir)
    }

    @Test("ProcessAntigravityExecutor.fetchUsageJSON throws credentials when not installed")
    func process_executor_not_installed_throws() async throws {
        let exec = ProcessAntigravityExecutor(customPath: "/nonexistent/path/to/agy")
        if !exec.isInstalled() {
            do {
                _ = try await exec.fetchUsageJSON()
                Issue.record("expected credentials error")
            } catch let err as AppError {
                if case .credentials(let msg) = err {
                    expectTrue(msg.contains("Antigravity instalado e autenticado"))
                } else {
                    Issue.record("expected credentials, got \(err)")
                }
            }
        }
    }

    @Test("ProcessAntigravityExecutor executes fake script returning usage JSON")
    func process_executor_runs_script() async throws {
        let scriptDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-script-\(UUID().uuidString)")
        try Paths.ensureDir(scriptDir)
        let scriptPath = scriptDir.appendingPathComponent("agy_mock").path
        let scriptContent = "#!/bin/sh\ncat << 'EOF'\n\(Fixtures.antigravityUsage200)\nEOF\n"
        try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        let exec = ProcessAntigravityExecutor(customPath: scriptPath)
        let data = try await exec.fetchUsageJSON()
        let str = String(data: data, encoding: .utf8) ?? ""
        expectTrue(str.contains("\"command\""))

        try? FileManager.default.removeItem(at: scriptDir)
    }

    @Test("ProcessAntigravityExecutor maps unauthenticated exit to AppError.http(401)")
    func process_executor_unauthenticated_exit() async throws {
        let scriptDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-script-\(UUID().uuidString)")
        try Paths.ensureDir(scriptDir)
        let scriptPath = scriptDir.appendingPathComponent("agy_unauth").path
        let scriptContent = "#!/bin/sh\necho 'Error: not logged in' >&2\nexit 1\n"
        try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        let exec = ProcessAntigravityExecutor(customPath: scriptPath)
        do {
            _ = try await exec.fetchUsageJSON()
            Issue.record("expected 401 error")
        } catch let err as AppError {
            expectTrue(err.isUnauthorized)
        }

        try? FileManager.default.removeItem(at: scriptDir)
    }

    @Test("ProcessAntigravityExecutor maps general failure exit to AppError.io")
    func process_executor_general_failure() async throws {
        let scriptDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-script-\(UUID().uuidString)")
        try Paths.ensureDir(scriptDir)
        let scriptPath = scriptDir.appendingPathComponent("agy_fail").path
        let scriptContent = "#!/bin/sh\necho 'network failure' >&2\nexit 2\n"
        try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        let exec = ProcessAntigravityExecutor(customPath: scriptPath)
        do {
            _ = try await exec.fetchUsageJSON()
            Issue.record("expected AppError.io")
        } catch let err as AppError {
            if case .io(let msg) = err {
                expectTrue(msg.contains("código 2"))
            } else {
                Issue.record("expected io error, got \(err)")
            }
        }

        try? FileManager.default.removeItem(at: scriptDir)
    }
}

private struct MockAntigravityExecutor: AntigravityExecuting, Sendable {
    var installed: Bool = true
    var data: Data? = Fixtures.data(Fixtures.antigravityUsage200)
    var error: AppError? = nil

    func isInstalled() -> Bool {
        installed
    }

    func fetchUsageJSON() async throws -> Data {
        if let error = error {
            throw error
        }
        if let data = data {
            return data
        }
        throw AppError.io("No mock data")
    }
}
