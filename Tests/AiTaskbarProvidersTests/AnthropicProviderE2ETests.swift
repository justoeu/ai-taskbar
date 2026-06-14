import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// In-memory `AnthropicCredentialReading` for driving AnthropicProvider
/// end-to-end without an "Always Allow" Keychain prompt. Class (not struct)
/// so the test can observe `writeBackCalls` after the provider mutates state.
private final class MockKeychainReader: AnthropicCredentialReading, @unchecked Sendable {
    var nextRead: AnthropicCredentials
    var writeBackCalls: [AnthropicCredentials] = []

    init(initial: AnthropicCredentials) { self.nextRead = initial }

    func read() throws -> AnthropicCredentials { nextRead }
    func writeBack(_ updated: AnthropicCredentials) throws {
        writeBackCalls.append(updated)
        nextRead = updated
    }
}

@Suite("AnthropicProvider end-to-end with mock keychain", .serialized)
struct AnthropicProviderE2ETests {
    let tmpCache: URL

    init() throws {
        StubURLProtocol.reset()
        tmpCache = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-ap-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCache)
    }

    @Test("fresh credentials + 200 → snapshot decoded")
    func fresh_credentials_decode_snapshot() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.anthropicUsage200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .anthropic, baseDir: tmpCache)
        let creds = AnthropicCredentials(
            accessToken: "fresh",
            refreshToken: "r",
            expiresAtMs: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            subscriptionType: "max",
            rateLimitTier: "max_5x"
        )
        let mock = MockKeychainReader(initial: creds)
        let provider = AnthropicProvider(credentialReader: mock, cache: cache, http: http)

        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case let .anthropic(snap) = outcome.snapshot else {
            Issue.record("expected anthropic snapshot")
            return
        }
        #expect(snap.planLabel == "Claude Max 5x")
        #expect(snap.session != nil)
        // No refresh was needed → writeBack not called.
        #expect(mock.writeBackCalls.isEmpty)
        try? FileManager.default.removeItem(at: tmpCache)
        StubURLProtocol.reset()
    }

    @Test("expired credentials trigger OAuth refresh + writeBack")
    func expired_credentials_refresh_and_writeback() async throws {
        var stage = 0
        StubURLProtocol.handler = { req in
            stage += 1
            if req.url?.path.contains("oauth/token") == true {
                return .init(data: Fixtures.data(Fixtures.oauthRefresh200))
            }
            return .init(data: Fixtures.data(Fixtures.anthropicUsage200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .anthropic, baseDir: tmpCache)
        let expired = AnthropicCredentials(
            accessToken: "old",
            refreshToken: "old.r",
            // Already expired
            expiresAtMs: Int64(Date().addingTimeInterval(-600).timeIntervalSince1970 * 1000),
            subscriptionType: "pro",
            rateLimitTier: nil
        )
        let mock = MockKeychainReader(initial: expired)
        let provider = AnthropicProvider(credentialReader: mock, cache: cache, http: http)
        _ = try await provider.fetchUsage(forceRefresh: true)

        // writeBack should have been called exactly once with the new tokens.
        #expect(mock.writeBackCalls.count == 1)
        #expect(mock.writeBackCalls.first?.accessToken == "new.acc.tk")
        #expect(mock.writeBackCalls.first?.refreshToken == "new.ref.tk")
        // Sent the right Authorization header on the second request.
        let auth = StubURLProtocol.captured.last?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer new.acc.tk")
        // anthropic-beta header is required by the upstream API.
        let beta = StubURLProtocol.captured.last?.value(forHTTPHeaderField: "anthropic-beta")
        #expect(beta == AnthropicOAuth.betaHeader)
        try? FileManager.default.removeItem(at: tmpCache)
        StubURLProtocol.reset()
    }

    @Test("read-only mode: expired token is NOT refreshed and NOT written back")
    func read_only_mode_skips_refresh_and_writeback() async throws {
        var hitOAuth = false
        StubURLProtocol.handler = { req in
            if req.url?.path.contains("oauth/token") == true {
                hitOAuth = true
                return .init(data: Fixtures.data(Fixtures.oauthRefresh200))
            }
            return .init(data: Fixtures.data(Fixtures.anthropicUsage200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .anthropic, baseDir: tmpCache)
        let expired = AnthropicCredentials(
            accessToken: "old",
            refreshToken: "old.r",
            // Already expired — would trigger refresh if management were on.
            expiresAtMs: Int64(Date().addingTimeInterval(-600).timeIntervalSince1970 * 1000),
            subscriptionType: "pro",
            rateLimitTier: nil
        )
        let mock = MockKeychainReader(initial: expired)
        let provider = AnthropicProvider(credentialReader: mock, cache: cache,
                                         http: http, manageOAuthRefresh: false)
        _ = try await provider.fetchUsage(forceRefresh: true)

        // No OAuth exchange, no Keychain write-back: the monitor left the
        // shared credential untouched.
        #expect(hitOAuth == false)
        #expect(mock.writeBackCalls.isEmpty)
        // The stored (expired) access token was used as-is.
        let auth = StubURLProtocol.captured.last?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer old")
        try? FileManager.default.removeItem(at: tmpCache)
        StubURLProtocol.reset()
    }

    @Test("decode failure on malformed body raises AppError.schema")
    func decode_failure_on_malformed_body() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Data("not anthropic shape".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .anthropic, baseDir: tmpCache)
        let creds = AnthropicCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAtMs: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000))
        let mock = MockKeychainReader(initial: creds)
        let provider = AnthropicProvider(credentialReader: mock, cache: cache, http: http)
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
        try? FileManager.default.removeItem(at: tmpCache)
        StubURLProtocol.reset()
    }

    @Test("HTTP 500 falls back to cached snapshot when one exists")
    func http_500_falls_back_to_cache() async throws {
        var firstCall = true
        StubURLProtocol.handler = { _ in
            if firstCall {
                firstCall = false
                return .init(data: Fixtures.data(Fixtures.anthropicUsage200))
            }
            return .init(status: 500, data: Data("oh no".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .anthropic, baseDir: tmpCache, ttl: 0.001)
        let creds = AnthropicCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAtMs: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000))
        let mock = MockKeychainReader(initial: creds)
        let provider = AnthropicProvider(credentialReader: mock, cache: cache, http: http)

        _ = try await provider.fetchUsage(forceRefresh: true)
        try await Task.sleep(nanoseconds: 50_000_000)

        let second = try await provider.fetchUsage(forceRefresh: true)
        #expect(second.isStale, "post-500 fetch should serve stale cache")
        try? FileManager.default.removeItem(at: tmpCache)
        StubURLProtocol.reset()
    }
}
