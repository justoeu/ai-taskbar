import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("OpenAIProvider end-to-end via FileCredentialReader", .serialized)
struct OpenAIProviderE2ETests {
    let tmpDir: URL

    init() throws {
        StubURLProtocol.reset()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-op-\(UUID().uuidString)")
        try Paths.ensureDir(tmpDir)
    }

    private func writeAuthJSON(idToken: String,
                               accessToken: String = "a",
                               refreshToken: String = "r",
                               accountId: String? = "acc-123") throws -> URL {
        let url = tmpDir.appendingPathComponent("auth.json")
        var json = #"""
        {
          "tokens": {
            "access_token": "\#(accessToken)",
            "refresh_token": "\#(refreshToken)",
            "id_token": "\#(idToken)"
          }
        """#
        if let acc = accountId { json += #","account_id":"\#(acc)""# }
        json += "}"
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeJWT(planType: String?, expiresIn: TimeInterval = 3600) -> String {
        let header = Data("{\"alg\":\"none\"}".utf8).base64URLString()
        let exp = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
        var payload = "{\"exp\":\(exp)"
        if let p = planType {
            payload += ",\"https://api.openai.com/auth.chatgpt_plan_type\":\"\(p)\""
        }
        payload += "}"
        let payloadB64 = Data(payload.utf8).base64URLString()
        return "\(header).\(payloadB64)."
    }

    @Test("fresh JWT + 200 → snapshot with plan label from JWT")
    func fresh_token_decodes_snapshot() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.openaiUsage200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .openai, baseDir: tmpDir)
        let token = makeJWT(planType: "pro")
        _ = try writeAuthJSON(idToken: token)
        let creds = FileCredentialReader(path: tmpDir.appendingPathComponent("auth.json"))
        let provider = OpenAIProvider(credentials: creds, cache: cache, http: http)

        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case let .openai(snap) = outcome.snapshot else {
            Issue.record("expected openai snapshot")
            return
        }
        #expect(snap.planLabel == "ChatGPT Pro")
        try? FileManager.default.removeItem(at: tmpDir)
        StubURLProtocol.reset()
    }

    @Test("expired JWT triggers OAuth refresh + writes back new tokens")
    func expired_token_triggers_refresh_and_writeback() async throws {
        let oauthBody = #"""
        {"access_token":"new.acc","refresh_token":"new.ref","id_token":"\#(makeJWT(planType: "plus"))","expires_in":3600}
        """#
        StubURLProtocol.handler = { req in
            if req.url?.path.contains("oauth/token") == true {
                return .init(data: Data(oauthBody.utf8))
            }
            return .init(data: Fixtures.data(Fixtures.openaiUsage200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .openai, baseDir: tmpDir)
        // expired JWT (negative expiresIn).
        let expiredToken = makeJWT(planType: "free", expiresIn: -100)
        _ = try writeAuthJSON(idToken: expiredToken)
        let path = tmpDir.appendingPathComponent("auth.json")
        let creds = FileCredentialReader(path: path)
        let provider = OpenAIProvider(credentials: creds, cache: cache, http: http)

        _ = try await provider.fetchUsage(forceRefresh: true)

        // auth.json on disk should now carry the refreshed access_token.
        let reread = try creds.read()
        #expect(reread.tokens.accessToken == "new.acc")
        #expect(reread.tokens.refreshToken == "new.ref")

        // Auth header on the actual usage call uses the new access token.
        let usageReq = StubURLProtocol.captured.last
        #expect(usageReq?.value(forHTTPHeaderField: "Authorization") == "Bearer new.acc")
        try? FileManager.default.removeItem(at: tmpDir)
        StubURLProtocol.reset()
    }

    @Test("ChatGPT-Account-Id header is set when account_id present")
    func account_id_header_set_when_present() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.openaiUsage200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .openai, baseDir: tmpDir)
        _ = try writeAuthJSON(idToken: makeJWT(planType: "team"),
                              accountId: "acc-xyz")
        let creds = FileCredentialReader(
            path: tmpDir.appendingPathComponent("auth.json"))
        let provider = OpenAIProvider(credentials: creds, cache: cache, http: http)
        _ = try await provider.fetchUsage(forceRefresh: true)
        let req = StubURLProtocol.captured.last
        #expect(req?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acc-xyz")
        try? FileManager.default.removeItem(at: tmpDir)
        StubURLProtocol.reset()
    }

    @Test("decode failure on malformed body raises AppError.schema")
    func decode_failure_on_malformed_body() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Data("not openai shape".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .openai, baseDir: tmpDir)
        _ = try writeAuthJSON(idToken: makeJWT(planType: "plus"))
        let creds = FileCredentialReader(
            path: tmpDir.appendingPathComponent("auth.json"))
        let provider = OpenAIProvider(credentials: creds, cache: cache, http: http)
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
        try? FileManager.default.removeItem(at: tmpDir)
        StubURLProtocol.reset()
    }

    @Test("planLabel cache miss re-reads credentials and primes the cache")
    func planLabel_cache_miss_reads_credentials() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.openaiUsage200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .openai, baseDir: tmpDir)
        // Seed cache with a stale payload BEFORE the first fetch, so the
        // provider serves from cache and the label getter takes the
        // cache-miss → read-credentials path.
        try cache.writePayload(Fixtures.data(Fixtures.openaiUsage200))
        let token = makeJWT(planType: "team")
        _ = try writeAuthJSON(idToken: token)
        let creds = FileCredentialReader(
            path: tmpDir.appendingPathComponent("auth.json"))
        let provider = OpenAIProvider(credentials: creds, cache: cache, http: http)
        let outcome = try await provider.fetchUsage(forceRefresh: false)
        if case let .openai(snap) = outcome.snapshot {
            #expect(snap.planLabel == "ChatGPT Team")
        }
        try? FileManager.default.removeItem(at: tmpDir)
        StubURLProtocol.reset()
    }

    @Test("stripPII returns raw bytes when body is not a JSON object")
    func stripPII_returns_raw_when_not_object() throws {
        let raw = Data("[1, 2, 3]".utf8)
        let stripped = try OpenAIProvider.stripPII(from: raw)
        #expect(stripped == raw, "non-object payloads pass through")
    }

    @Test("computePlanLabel returns nil for token without plan_type claim")
    func computePlanLabel_returns_nil_for_token_without_claim() {
        let header = Data("{\"alg\":\"none\"}".utf8).base64URLString()
        let payload = Data(#"{"sub":"u"}"#.utf8).base64URLString()
        let token = "\(header).\(payload)."
        #expect(OpenAIProvider.computePlanLabel(from: token) == nil)
    }

    @Test("PII fields are stripped before the cache write")
    func pii_fields_stripped_in_cache() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.openaiUsage200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .openai, baseDir: tmpDir)
        _ = try writeAuthJSON(idToken: makeJWT(planType: "plus"))
        let creds = FileCredentialReader(
            path: tmpDir.appendingPathComponent("auth.json"))
        let provider = OpenAIProvider(credentials: creds, cache: cache, http: http)
        _ = try await provider.fetchUsage(forceRefresh: true)

        let cached = cache.anyPayload() ?? Data()
        let cachedStr = String(data: cached, encoding: .utf8) ?? ""
        #expect(!cachedStr.contains("user_id"))
        #expect(!cachedStr.contains("account_id"))
        #expect(!cachedStr.contains("email"))
        try? FileManager.default.removeItem(at: tmpDir)
        StubURLProtocol.reset()
    }
}

private extension Data {
    func base64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
