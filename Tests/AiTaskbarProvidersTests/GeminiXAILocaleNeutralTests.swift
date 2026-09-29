import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// Regression suite for the B4-i18n batch (CQ-AUR-001 / ARCH-ATL-001,
/// BEST-ATE-004, BUG-ART-009).
///
/// CLAUDE.md: "Never build a user-facing sentence inside a wire type; emit
/// structure and let the localized view render it." Gemini and xAI used to
/// bake Portuguese sentences into snapshots and errors, so every en/es user
/// read Portuguese on those two cards.
@Suite("Gemini + xAI emit structure, not prose", .serialized)
struct GeminiXAILocaleNeutralTests {

    // MARK: CQ-AUR-001 / ARCH-ATL-001

    /// Portuguese fragments that were hard-coded in Providers. Any of them
    /// reappearing means a sentence is again being built below the view.
    private static let portugueseMarkers = [
        "Para conseguir", "Para monitorar", "necessário", "não ", "Operação",
        "Tempo limite", "falhou", "Erro no", "Tente novamente", "código",
        "Instale", "autenticado",
    ]

    @Test("Providers sources contain no Portuguese user-facing prose")
    func providers_sources_carry_no_portuguese_prose() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("Sources/AiTaskbarProviders")
        let files = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for marker in Self.portugueseMarkers where text.contains(marker) {
                hits.append("\(file.lastPathComponent): \(marker)")
            }
        }
        #expect(hits == [])
    }

    // MARK: BEST-ATE-004

    @Test("agy schema drift surfaces the agy decode error, not a base_url hint")
    func agy_schema_drift_reports_agy_decode_error() async throws {
        // `remaining_fraction` drifted from number to string: the agy decode
        // fails. It used to be swallowed by `try?` and re-reported as the AI
        // Studio "base_url may be wrong", an endpoint that was never called.
        let drifted = #"""
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[
            {"id":"gemini-5h","window":"5h","remaining_fraction":"0.5"}]}]}}}
        """#
        let message = try await Self.fetchError(agyPayload: Data(drifted.utf8))
        expectTrue(message.contains("agy usage decode"), "\(message)")
        expectFalse(message.contains("base_url"), "\(message)")
    }

    // MARK: BUG-ART-009

    @Test("Antigravity bucket without remaining_fraction draws no bar")
    func antigravity_missing_remaining_fraction_is_unknown() throws {
        let body = #"""
        {"command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h"}]}]}}}
        """#
        let parsed = try JSONDecoder().decode(AntigravityUsageResponse.self,
                                              from: Data(body.utf8))
        let snap = parsed.toSnapshot()
        // Unknown is not "100% remaining": a proto3 encoder omits a zero
        // (exhausted) double, so defaulting to 1.0 could show a spent bucket
        // as 0% used.
        expectTrue(snap.fiveHour == nil)
    }

    @Test("stale fallback keeps 401 for agy not signed in, so the re-login banner shows")
    func stale_guidance_keeps_401_status() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-b4-\(UUID().uuidString)")
        try Paths.ensureDir(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fetch = CachedFetch(cache: DiskCache(vendor: .gemini, baseDir: dir))
        let fixture = Fixtures.data(Fixtures.antigravityUsage200)
        let decode: (Data) throws -> Int = { $0.count }
        _ = try await fetch.run(forceRefresh: true, decode: decode, fetch: { fixture })
        let outcome = try await fetch.run(forceRefresh: true, decode: decode, fetch: {
            throw AppError.guidance(.antigravityNotAuthenticated)
        })
        #expect(outcome.isStale)
        expectTrue(outcome.lastError?.status == 401)
    }

    @Test("agy SUCCESS payload decodes through the agy branch")
    func agy_payload_decodes() async throws {
        let snap = try await Self.fetchSnapshot(agyPayload: Fixtures.data(Fixtures.antigravityUsage200))
        expectTrue(snap?.isAntigravityActive == true)
        expectTrue(snap?.disclaimer == .antigravityRequired)
    }

    @Test("agy context canceled payload maps to structured guidance")
    func agy_canceled_payload_is_guidance() async throws {
        let body = #"{"conversation_id":"","status":"ERROR","response":"","error":"context canceled"}"#
        let message = try await Self.fetchError(agyPayload: Data(body.utf8))
        #expect(message == AppError.guidance(.antigravityCanceled).description)
    }

    /// DUP-MAE-003: the cached-payload path read `error ?? response`, so an
    /// empty `error` hid agy's real message behind "agy: ", while the live
    /// executor already skipped empty fields. Both now share one mapping.
    @Test("an empty agy error falls back to the response text, as the executor does")
    func agy_empty_error_uses_response() async throws {
        let body = #"{"conversation_id":"","status":"ERROR","response":"quota backend down","error":""}"#
        let message = try await Self.fetchError(agyPayload: Data(body.utf8))
        #expect(message == AppError.io("agy: quota backend down").description)
    }

    @Test("non-JSON payload is a schema error")
    func non_json_payload_is_schema_error() async throws {
        let message = try await Self.fetchError(agyPayload: Data("not json".utf8))
        expectTrue(message.contains("gemini payload is not JSON"), "\(message)")
    }

    @Test("a top-level JSON array is not an agy payload")
    func json_array_is_not_agy() throws {
        expectFalse(try GeminiProvider.isAntigravityPayload(Data("[1]".utf8)))
    }

    // MARK: helpers

    private static func fetchSnapshot(agyPayload: Data) async throws -> GeminiSnapshot? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-b4-\(UUID().uuidString)")
        try Paths.ensureDir(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = try await makeProvider(dir: dir, payload: agyPayload)
            .fetchUsage(forceRefresh: true)
        if case .gemini(let s) = outcome.snapshot { return s }
        return nil
    }

    private static func makeProvider(dir: URL, payload: Data) -> GeminiProvider {
        GeminiProvider(
            credentials: EnvOrConfigCredentialReader(envVarName: "_UNSET_GEMINI_B4",
                                                     inlineKey: nil,
                                                     vendorName: "Gemini"),
            cache: DiskCache(vendor: .gemini, baseDir: dir),
            http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]),
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            antigravity: FixedAntigravityExecutor(payload: payload),
            preferAntigravity: true
        )
    }

    private static func fetchError(agyPayload: Data) async throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-b4-\(UUID().uuidString)")
        try Paths.ensureDir(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = makeProvider(dir: dir, payload: agyPayload)
        do {
            _ = try await provider.fetchUsage(forceRefresh: true)
        } catch {
            return String(describing: error)
        }
        Issue.record("expected fetchUsage to throw")
        return ""
    }
}

private struct FixedAntigravityExecutor: AntigravityExecuting, Sendable {
    let payload: Data
    func isInstalled() -> Bool { true }
    func fetchUsageJSON() async throws -> Data { payload }
}
