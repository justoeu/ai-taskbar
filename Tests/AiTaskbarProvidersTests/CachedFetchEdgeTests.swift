import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("CachedFetch fall-through paths", .serialized)
struct CachedFetchEdgeTests {
    init() { StubURLProtocol.reset() }

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

    @Test("cancelled Task during fetch raises an error rather than returning a value")
    func cancelled_task_raises_cancellation() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cfeC-\(UUID().uuidString)")
        try? Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = DiskCache(vendor: .openrouter, baseDir: tmp, ttl: 60)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET", inlineKey: "k", vendorName: "OpenRouter")
        // Sleep long enough that cancel always lands while the request is
        // still in flight — turns the original "either outcome is acceptable"
        // test (which could not fail) into a deterministic assertion.
        StubURLProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 5)
            return .init(data: Data())
        }
        let provider = OpenRouterProvider(
            credentials: creds,
            cache: cache,
            http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]))
        let task = Task<FetchOutcome, Error> {
            try await provider.fetchUsage(forceRefresh: true)
        }
        // Let the task enter the URLSession await before cancelling. 50ms is
        // generous for the StubURLProtocol handshake start.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected the cancelled task to throw, not return a value")
        } catch {
            // Either CancellationError (cancel observed at checkCancellation)
            // or AppError.transport (URLSession surfaced URLError.cancelled).
            // Both prove the cancel was observed — that's the assertion.
            // The previous test accepted ANY outcome including success,
            // which made it documentation-only.
            let isCancellation = error is CancellationError
            let isAppErrorTransport = (error as? AppError).map { err in
                if case .transport = err { return true }
                if case .other = err { return true }  // wrapped URLError
                return false
            } ?? false
            #expect(isCancellation || isAppErrorTransport,
                    "expected CancellationError or AppError transport, got \(error)")
        }
        StubURLProtocol.reset()
    }
}
