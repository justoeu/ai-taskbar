import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("xAI provider", .serialized)
struct XAIProviderTests {
    let tmpCacheDir: URL

    init() throws {
        StubURLProtocol.reset()
        tmpCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-xai-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCacheDir)
    }

    @Test("uses Bearer prefix on Authorization header")
    func uses_bearer_prefix() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.contains("prepaid") {
                return .init(data: Fixtures.data(Fixtures.xaiPrepaidBalance200))
            }
            return .init(data: Fixtures.data(Fixtures.xaiInvoicePreview200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .xai, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_XAI",
            inlineKey: "xai-mgmt-test",
            vendorName: "xAI"
        )
        let provider = XAIProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://management-api.x.ai")!,
            teamId: "team-abc"
        )
        _ = try await provider.fetchUsage(forceRefresh: true)

        let req = StubURLProtocol.captured.first {
            $0.url?.absoluteString.contains("management-api.x.ai") == true
        }
        let auth = req?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer xai-mgmt-test", "xAI must receive `Bearer ...`")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("hits prepaid balance and invoice preview paths")
    func hits_both_billing_paths() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.contains("prepaid") {
                return .init(data: Fixtures.data(Fixtures.xaiPrepaidBalance200))
            }
            return .init(data: Fixtures.data(Fixtures.xaiInvoicePreview200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .xai, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_XAI_2",
            inlineKey: "k",
            vendorName: "xAI"
        )
        let provider = XAIProvider(
            credentials: creds,
            cache: cache,
            http: http,
            baseURL: URL(string: "https://management-api.x.ai")!,
            teamId: "team-xyz"
        )
        _ = try await provider.fetchUsage(forceRefresh: true)

        let paths = StubURLProtocol.captured.compactMap { $0.url?.path }
        #expect(paths.contains { $0.contains("/v1/billing/teams/team-xyz/prepaid/balance") })
        #expect(paths.contains { $0.contains("/v1/billing/teams/team-xyz/postpaid/invoice/preview") })
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("parses prepaid + monthly spend snapshot")
    func parses_canonical_snapshot() async throws {
        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.contains("prepaid") {
                return .init(data: Fixtures.data(Fixtures.xaiPrepaidBalance200))
            }
            return .init(data: Fixtures.data(Fixtures.xaiInvoicePreview200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .xai, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_XAI_3",
            inlineKey: "k",
            vendorName: "xAI"
        )
        let provider = XAIProvider(
            credentials: creds, cache: cache, http: http,
            baseURL: URL(string: "https://management-api.x.ai")!,
            teamId: "team-1"
        )
        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case let .xai(snap) = outcome.snapshot else {
            Issue.record("expected xai snapshot")
            return
        }
        #expect(snap.prepaidUSD == 45.0)
        #expect(snap.spentUSD == 12.5)
        #expect(snap.spendingLimitUSD == 200.0)
        #expect(snap.balance?.detail == "$45.00 available")
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("missing team_id throws credentials error")
    func missing_team_id_throws() async throws {
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .xai, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_XAI_4",
            inlineKey: "k",
            vendorName: "xAI"
        )
        let provider = XAIProvider(
            credentials: creds, cache: cache, http: http,
            baseURL: URL(string: "https://management-api.x.ai")!,
            teamId: "   "
        )
        do {
            _ = try await provider.fetchUsage(forceRefresh: true)
            Issue.record("expected credentials error for empty team_id")
        } catch let error as AppError {
            #expect(error.description.contains("team_id"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }
}
