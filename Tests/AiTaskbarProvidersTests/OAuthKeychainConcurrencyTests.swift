import Testing
import Foundation
import os
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// Thread-safe in-memory reader. It records whether each blocking call ran on
/// a cooperative-pool thread, and optionally blocks `authorizePersistently`
/// on a semaphore to stand in for a SecurityAgent dialog waiting on the user.
private final class ProbingKeychainReader: AnthropicCredentialReading, @unchecked Sendable {
    private let lock = NSLock()
    private var current: AnthropicCredentials
    private var readsOnPool = 0
    private var readsTotal = 0
    private var authorizeOnPool: Bool?
    private var writes = 0
    private var rotateAfterFirstRead: AnthropicCredentials?
    let authorizeGate: DispatchSemaphore?

    /// `rotateAfterFirstRead` stands in for the Claude Code CLI rotating the
    /// item right after this app's first read returned the old credential.
    init(_ credentials: AnthropicCredentials, authorizeGate: DispatchSemaphore? = nil,
         rotateAfterFirstRead: AnthropicCredentials? = nil) {
        current = credentials
        self.authorizeGate = authorizeGate
        self.rotateAfterFirstRead = rotateAfterFirstRead
    }

    var poolReads: Int { lock.withLock { readsOnPool } }
    var totalReads: Int { lock.withLock { readsTotal } }
    var writeBacks: Int { lock.withLock { writes } }
    var authorizeRanOnPool: Bool? { lock.withLock { authorizeOnPool } }

    func read() throws -> AnthropicCredentials {
        let onPool = CooperativePoolProbe.isOnCooperativePool
        return lock.withLock {
            readsTotal += 1
            if onPool { readsOnPool += 1 }
            let served = current
            if let rotated = rotateAfterFirstRead {
                current = rotated
                rotateAfterFirstRead = nil
            }
            return served
        }
    }

    func authorizePersistently() throws -> KeychainAccessAuthorizer.Outcome {
        let onPool = CooperativePoolProbe.isOnCooperativePool
        lock.withLock { authorizeOnPool = onPool }
        if let authorizeGate {
            _ = authorizeGate.wait(timeout: .now() + 5)
        }
        return .authorized
    }

    func writeBack(_ updated: AnthropicCredentials) throws {
        lock.withLock {
            writes += 1
            current = updated
        }
    }
}

/// Counts token-endpoint exchanges across the URLSession loader threads.
private final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite("OAuth single-flight and Keychain off-pool hops", .serialized)
struct OAuthKeychainConcurrencyTests {
    private static let callers = 8
    private static let iterations = 25

    private static func tmpDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-oauth-race-\(UUID().uuidString)")
        try Paths.ensureDir(url)
        return url
    }

    private static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func jwt(expiresIn: TimeInterval) -> String {
        let exp = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
        return "\(base64URL("{\"alg\":\"none\"}")).\(base64URL("{\"exp\":\(exp)}"))."
    }

    private static func writeCodexAuth(to url: URL, idToken: String,
                                       accessToken: String, refreshToken: String) throws {
        let json = #"""
        {"tokens":{"access_token":"\#(accessToken)","refresh_token":"\#(refreshToken)","id_token":"\#(idToken)"},"account_id":"acc-1"}
        """#
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Runs `callers` concurrent fetches that are all released by one gate,
    /// so they race into the refresh path together.
    private static func raceFetches(_ provider: any UsageProvider) async {
        let gate = DispatchSemaphore(value: 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<callers {
                group.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global().async {
                            gate.wait()
                            c.resume()
                        }
                    }
                    _ = try? await provider.fetchUsage(forceRefresh: true)
                }
            }
            for _ in 0..<callers { gate.signal() }
        }
    }

    // MARK: RACE-CRO-001

    @Test("OpenAI: concurrent callers with an expiring token run exactly one exchange")
    func openai_concurrent_refresh_exchanges_once() async throws {
        let hits = HitCounter()
        let freshID = Self.jwt(expiresIn: 3600)
        let body = #"{"access_token":"new.acc","refresh_token":"new.ref","id_token":"\#(freshID)","expires_in":3600}"#
        StubURLProtocol.reset()
        StubURLProtocol.handler = { req in
            if req.url?.path.contains("oauth/token") == true {
                hits.increment()
                Thread.sleep(forTimeInterval: 0.05)
                return .init(data: Data(body.utf8))
            }
            return .init(data: Fixtures.data(Fixtures.openaiUsage200))
        }
        defer { StubURLProtocol.reset() }
        var extraExchanges = 0
        for _ in 0..<Self.iterations {
            let dir = try Self.tmpDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("auth.json")
            try Self.writeCodexAuth(to: path, idToken: Self.jwt(expiresIn: -100),
                                    accessToken: "old.acc", refreshToken: "old.ref")
            let before = hits.count
            let provider = OpenAIProvider(
                credentials: FileCredentialReader(path: path),
                cache: DiskCache(vendor: .openai, baseDir: dir),
                http: .stubbed(protocols: [StubURLProtocol.self]),
                manageOAuthRefresh: true)
            await Self.raceFetches(provider)
            extraExchanges += max(0, hits.count - before - 1)
        }
        #expect(extraExchanges == 0)
    }

    @Test("Anthropic: concurrent callers with an expired token run exactly one exchange")
    func anthropic_concurrent_refresh_exchanges_once() async throws {
        let hits = HitCounter()
        let body = #"{"access_token":"new.acc","refresh_token":"new.ref","expires_in":3600}"#
        StubURLProtocol.reset()
        StubURLProtocol.handler = { req in
            if req.url?.path.contains("oauth/token") == true {
                hits.increment()
                Thread.sleep(forTimeInterval: 0.05)
                return .init(data: Data(body.utf8))
            }
            return .init(data: Fixtures.data(Fixtures.anthropicUsage200))
        }
        defer { StubURLProtocol.reset() }
        var extraExchanges = 0
        for _ in 0..<Self.iterations {
            let dir = try Self.tmpDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let before = hits.count
            let reader = ProbingKeychainReader(AnthropicCredentials(
                accessToken: "old.acc", refreshToken: "old.ref",
                expiresAtMs: Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000)))
            let provider = AnthropicProvider(
                credentialReader: reader,
                cache: DiskCache(vendor: .anthropic, baseDir: dir),
                http: .stubbed(protocols: [StubURLProtocol.self]),
                manageOAuthRefresh: true)
            await Self.raceFetches(provider)
            extraExchanges += max(0, hits.count - before - 1)
        }
        #expect(extraExchanges == 0)
    }

    // MARK: RACE-CRO-002

    @Test("OpenAI: a 401 after another process rotated auth.json reuses the new token, no exchange")
    func openai_reactive_refresh_skips_rotated_refresh_token() async throws {
        let dir = try Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("auth.json")
        let idToken = Self.jwt(expiresIn: 3600)
        try Self.writeCodexAuth(to: path, idToken: idToken,
                                accessToken: "old.acc", refreshToken: "old.ref")
        let hits = HitCounter()
        StubURLProtocol.reset()
        StubURLProtocol.handler = { req in
            if req.url?.path.contains("oauth/token") == true {
                hits.increment()
                return .init(status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer old.acc" {
                // Another fetch (or the Codex CLI) rotates the credential while
                // this request is in flight, then the server rejects the old AT.
                try? Self.writeCodexAuth(to: path, idToken: idToken,
                                         accessToken: "rotated.acc", refreshToken: "rotated.ref")
                return .init(status: 401, data: Data(#"{"error":"expired"}"#.utf8))
            }
            return .init(data: Fixtures.data(Fixtures.openaiUsage200))
        }
        defer { StubURLProtocol.reset() }
        let provider = OpenAIProvider(
            credentials: FileCredentialReader(path: path),
            cache: DiskCache(vendor: .openai, baseDir: dir),
            http: .stubbed(protocols: [StubURLProtocol.self]),
            manageOAuthRefresh: true)

        let outcome = try? await provider.fetchUsage(forceRefresh: true)

        #expect(hits.count == 0)
        expectTrue(outcome.map { !$0.isStale } ?? false)
        #expect(StubURLProtocol.captured.last?.value(forHTTPHeaderField: "Authorization")
                == "Bearer rotated.acc")
    }

    @Test("Anthropic: a refresh after Claude Code rotated the item reuses the new token, no exchange")
    func anthropic_refresh_skips_rotated_refresh_token() async throws {
        let dir = try Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reader = ProbingKeychainReader(
            AnthropicCredentials(
                accessToken: "old.acc", refreshToken: "old.ref",
                expiresAtMs: Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000)),
            rotateAfterFirstRead: AnthropicCredentials(
                accessToken: "rotated.acc", refreshToken: "rotated.ref",
                expiresAtMs: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)))
        let hits = HitCounter()
        StubURLProtocol.reset()
        StubURLProtocol.handler = { req in
            if req.url?.path.contains("oauth/token") == true {
                hits.increment()
                return .init(status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            return .init(data: Fixtures.data(Fixtures.anthropicUsage200))
        }
        defer { StubURLProtocol.reset() }
        let provider = AnthropicProvider(
            credentialReader: reader,
            cache: DiskCache(vendor: .anthropic, baseDir: dir),
            http: .stubbed(protocols: [StubURLProtocol.self]),
            manageOAuthRefresh: true)

        let outcome = try? await provider.fetchUsage(forceRefresh: true)

        #expect(hits.count == 0)
        #expect(reader.writeBacks == 0)
        expectTrue(outcome.map { !$0.isStale } ?? false)
        #expect(StubURLProtocol.captured.last?.value(forHTTPHeaderField: "Authorization")
                == "Bearer rotated.acc")
    }

    // MARK: RACE-CRO-004

    @Test("Anthropic: a cache hit never reads the Keychain on the cooperative pool")
    func anthropic_cache_hit_plan_label_reads_off_pool() async throws {
        let dir = try Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DiskCache(vendor: .anthropic, baseDir: dir)
        try cache.writePayload(Fixtures.data(Fixtures.anthropicUsage200))
        let reader = ProbingKeychainReader(AnthropicCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAtMs: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            subscriptionType: "max", rateLimitTier: "default_claude_max_20x"))
        StubURLProtocol.reset()
        let provider = AnthropicProvider(credentialReader: reader, cache: cache,
                                         http: .stubbed(protocols: [StubURLProtocol.self]))

        let outcome = try await provider.fetchUsage(forceRefresh: false)

        #expect(reader.poolReads == 0)
        #expect(StubURLProtocol.captured.isEmpty)
        guard case let .anthropic(snap) = outcome.snapshot else {
            Issue.record("expected anthropic snapshot")
            return
        }
        #expect(snap.planLabel == "Claude Max 20x")
    }

    // MARK: BEST-ATE-001

    @Test("Authorize runs off the cooperative pool and does not starve readOffPool")
    func authorize_runs_off_cooperative_pool() async throws {
        let gate = DispatchSemaphore(value: 0)
        let reader = ProbingKeychainReader(AnthropicCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAtMs: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)),
            authorizeGate: gate)
        let dir = try Self.tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = AnthropicProvider(credentialReader: reader,
                                         cache: DiskCache(vendor: .anthropic, baseDir: dir),
                                         http: .stubbed(protocols: [StubURLProtocol.self]))

        let authorization = Task { try await provider.authorizeCredentialsOffPool() }
        // The dialog is "open": a concurrent credential read must still finish.
        let read = try await reader.readOffPool()
        gate.signal()
        let authorized = try await authorization.value

        #expect(read.accessToken == "a")
        #expect(authorized)
        expectFalse(reader.authorizeRanOnPool ?? true)
    }
}
