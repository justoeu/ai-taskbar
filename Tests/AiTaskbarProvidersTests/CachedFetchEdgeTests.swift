import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("CachedFetch fall-through paths", .serialized)
struct CachedFetchEdgeTests {
    init() { StubURLProtocol.reset() }

    @Test("CachedFetch decodes a generic service-status outcome")
    func decodes_generic_service_status_outcome() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cfgeneric-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fetcher = CachedFetch(cache: DiskCache(vendor: .kimi, baseDir: tmp))
        let expected = VendorServiceStatus(
            vendorId: .kimi,
            level: .operational,
            coverage: .full,
            summary: "Operational",
            sourceURL: URL(string: "https://status.moonshot.cn"),
            sourceUpdatedAt: nil,
            incidents: []
        )

        let outcome: ServiceStatusOutcome = try await fetcher.run(
            forceRefresh: true,
            decode: { _ in expected },
            fetch: { Data("status".utf8) }
        )

        #expect(outcome.snapshot == expected)
        #expect(!outcome.isStale)
    }

    /// ARCH-ATL-006: a fresh cache entry the current decoder rejects (e.g. a
    /// schema change across an upgrade) must not fail every tick for the TTL;
    /// the lifecycle falls through to the network and overwrites the entry.
    @Test("fresh but undecodable cache falls through to the fetcher")
    func fresh_undecodable_cache_falls_through_to_fetch() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cfbad-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = DiskCache(vendor: .kimi, baseDir: tmp, ttl: 600)
        try cache.writePayload(Data("old-schema".utf8))
        let fetcher = CachedFetch(cache: cache)
        struct SchemaError: Error {}
        let fetches = LockedCounter()

        let outcome: CachedOutcome<String> = try await fetcher.run(
            forceRefresh: false,
            decode: { data in
                let text = String(decoding: data, as: UTF8.self)
                guard text == "new-schema" else { throw SchemaError() }
                return text
            },
            fetch: { fetches.increment(); return Data("new-schema".utf8) }
        )

        #expect(outcome.snapshot == "new-schema")
        #expect(!outcome.isStale)
        #expect(fetches.value == 1)
        #expect(cache.anyPayload() == Data("new-schema".utf8))
    }

    @Test("forceRefresh=false with fresh cache skips fetcher")
    func uses_fresh_cache_without_fetcher() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cfeF-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = DiskCache(vendor: .openrouter, baseDir: tmp, ttl: 60)
        // Seed cache with a valid payload.
        let credits = #"{"data":{"total_credits":10,"total_usage":1}}"#
        let key = #"{"data":{"label":"p","usage":1,"limit":10}}"#
        let payload = #"{"credits":\#(credits),"key":\#(key)}"#
        try cache.writePayload(Data(payload.utf8))

        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET", inlineKey: "k", vendorName: "OpenRouter")
        StubURLProtocol.handler = { _ in
            Issue.record("network should not be called when cache is fresh")
            return .init(data: Data())
        }
        let provider = OpenRouterProvider(
            credentials: creds,
            cache: cache,
            http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]))
        let outcome = try await provider.fetchUsage(forceRefresh: false)
        #expect(!outcome.isStale)
        StubURLProtocol.reset()
    }

    @Test("network failure without cached payload propagates as AppError")
    func no_cache_and_network_failure_propagates() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cfne-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = DiskCache(vendor: .openrouter, baseDir: tmp, ttl: 60)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET", inlineKey: "k", vendorName: "OpenRouter")
        StubURLProtocol.handler = { _ in
            .failing(.cannotConnectToHost)
        }
        let provider = OpenRouterProvider(
            credentials: creds, cache: cache,
            http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]))
        do {
            _ = try await provider.fetchUsage(forceRefresh: true)
            Issue.record("expected throw — no cache + failed network")
        } catch let err as AppError {
            // wrapping wraps any non-AppError into .other; transport errors
            // come through as .transport.
            switch err {
            case .transport, .other: break
            default: Issue.record("unexpected \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
        StubURLProtocol.reset()
    }

    @Test("cancelled Task during fetch raises CancellationError, not a value or a wrapped error")
    func cancelled_task_raises_cancellation() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cfeC-\(UUID().uuidString)")
        try? Paths.ensureDir(tmp)
        defer {
            try? FileManager.default.removeItem(at: tmp)
            StubURLProtocol.reset()
        }
        let cache = DiskCache(vendor: .openrouter, baseDir: tmp, ttl: 60)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET", inlineKey: "k", vendorName: "OpenRouter")
        // The stub announces that a request is in flight, then holds it until
        // the test has cancelled: no timing guess decides whether the cancel
        // lands before or after the network call. OpenRouter fires three
        // requests; only the first is held, the rest pass once released.
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let gate = StubGate()
        StubURLProtocol.handler = { _ in
            enteredContinuation.yield()
            gate.waitUntilReleased()
            return .init(data: Data())
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        let provider = OpenRouterProvider(
            credentials: creds,
            cache: cache,
            http: HTTPClient(session: session))
        let task = Task<FetchOutcome, Error> {
            try await provider.fetchUsage(forceRefresh: true)
        }
        for await _ in entered { break }
        task.cancel()
        gate.release()

        do {
            _ = try await task.value
            Issue.record("expected the cancelled task to throw, not return a value")
        } catch {
            // HTTPClient maps URLError.cancelled to CancellationError, and the
            // post-network checkCancellation throws it too. Anything else
            // (AppError.other, .transport, .schema from the empty body) means
            // the cancel was lost or re-wrapped.
            #expect(error is CancellationError, "expected CancellationError, got \(error)")
        }
        // Drain the sibling requests the cancel left behind. StubURLProtocol
        // state is process-wide, so a request still loading here would be
        // captured by (and served the handler of) the NEXT suite's test —
        // that is how this test broke GeminiProviderTests' header check.
        session.invalidateAndCancel()
        for _ in 0..<500 where await !session.allTasks.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await session.allTasks.isEmpty)
    }

    @Test("semantic decode failure preserves and serves the last known-good payload")
    func semantic_failure_preserves_last_good_payload() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cfsemantic-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp, ttl: 0)
        let good = Data("good".utf8)
        try cache.writePayload(good)
        let fetcher = CachedFetch(cache: cache)

        let outcome: CachedOutcome<String> = try await fetcher.run(
            forceRefresh: true,
            decode: { data in
                guard data == good else { throw AppError.schema("semantic failure") }
                return "decoded-good"
            },
            fetch: { Data("bad".utf8) }
        )

        #expect(outcome.snapshot == "decoded-good")
        #expect(outcome.isStale)
        #expect(cache.anyPayload() == good)
    }

    @Test("cache outcomes retain the payload modification time as fetchedAt")
    func cache_outcome_fetched_at_matches_payload_age() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cftime-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp, ttl: 0)
        try cache.writePayload(Data("good".utf8))
        let payloadURL = tmp.appendingPathComponent("usage.json")
        let cachedAt = Date.now.addingTimeInterval(-120)
        try FileManager.default.setAttributes(
            [.modificationDate: cachedAt],
            ofItemAtPath: payloadURL.path
        )

        let outcome: CachedOutcome<String> = try await CachedFetch(cache: cache).run(
            forceRefresh: true,
            decode: { String(decoding: $0, as: UTF8.self) },
            fetch: { throw AppError.transport("offline") }
        )

        #expect(outcome.isStale)
        #expect(abs(outcome.fetchedAt.timeIntervalSince(cachedAt)) < 2)
    }
}

/// One-shot latch for a blocking StubURLProtocol handler: callers wait until
/// `release()`; after that every call returns immediately.
private final class StubGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let semaphore = DispatchSemaphore(value: 0)

    func waitUntilReleased() {
        lock.lock()
        let open = released
        lock.unlock()
        if open { return }
        _ = semaphore.wait(timeout: .now() + 5)
        semaphore.signal() // pass the wake-up on to any other waiter
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
        semaphore.signal()
    }
}

/// Thread-safe call counter for `@Sendable` fetch closures.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
