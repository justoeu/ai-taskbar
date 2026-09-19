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
            teamId: "   ",
            preferGrokCLI: false
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

    @Test("golden: Grok billing response matches canonical snapshot")
    func golden_grok_billing() throws {
        let resp = try SharedCoders.decoder.decode(
            GrokBillingResponse.self,
            from: Fixtures.data(Fixtures.grokBillingCredits200)
        )
        let snap = resp.toSnapshot(planLabel: "SuperGrok Heavy")
        expectTrue(snap.planLabel == "SuperGrok Heavy")
        expectTrue(snap.weekly?.label == "Weekly")
        #expect(snap.weekly?.utilizationPercent == 3.0)
        expectTrue(snap.weekly?.detail == "3% used")
        expectTrue(snap.weekly?.resetsAt != nil)
        expectTrue(snap.balance?.detail == "$40.00 available")
        #expect(snap.prepaidUSD == 40.0)
        expectTrue(snap.disclaimer == "Para conseguir monitorar o Grok, é necessário ter o Grok instalado e autenticado.")
    }

    @Test("golden: Grok settings response decodes subscription tier")
    func golden_grok_settings() throws {
        let resp = try SharedCoders.decoder.decode(
            GrokSettingsResponse.self,
            from: Fixtures.data(Fixtures.grokSettings200)
        )
        expectTrue(resp.subscriptionTierDisplay == "SuperGrok Heavy")
    }

    @Test("Grok CLI mode fetches billing and settings via Bearer token")
    func grok_cli_mode_fetches_billing_and_settings() async throws {
        let authFile = tmpCacheDir.appendingPathComponent("auth.json")
        try Fixtures.grokAuthJSON.write(to: authFile, atomically: true, encoding: .utf8)

        StubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path.contains("billing") {
                return .init(data: Fixtures.data(Fixtures.grokBillingCredits200))
            }
            if path.contains("settings") {
                return .init(data: Fixtures.data(Fixtures.grokSettings200))
            }
            return .init(status: 404, data: Data())
        }

        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .xai, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_XAI_5",
            inlineKey: nil,
            vendorName: "xAI"
        )
        let provider = XAIProvider(
            credentials: creds,
            grokAuthReader: GrokAuthReader(path: authFile),
            cache: cache,
            http: http,
            baseURL: URL(string: "https://management-api.x.ai")!,
            grokBaseURL: URL(string: "https://cli-chat-proxy.grok.com")!,
            teamId: "",
            preferGrokCLI: true
        )

        expectTrue(provider.credentialFileURL == authFile)

        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case let .xai(snap) = outcome.snapshot else {
            Issue.record("expected xai snapshot")
            return
        }

        expectTrue(snap.planLabel == "SuperGrok Heavy")
        #expect(snap.weekly?.utilizationPercent == 3.0)
        expectTrue(snap.weekly?.detail == "3% used")
        #expect(snap.prepaidUSD == 40.0)

        let billingReq = StubURLProtocol.captured.first {
            $0.url?.path.contains("billing") == true
        }
        let auth = billingReq?.value(forHTTPHeaderField: "Authorization")
        expectTrue(auth == "Bearer test-grok-token-12345")

        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }

    @Test("missing Grok auth and missing team_id throws friendly disclaimer")
    func grok_missing_auth_throws_disclaimer() async throws {
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let cache = DiskCache(vendor: .xai, baseDir: tmpCacheDir)
        let creds = EnvOrConfigCredentialReader(
            envVarName: "_UNSET_XAI_6",
            inlineKey: nil,
            vendorName: "xAI"
        )
        let nonExistentAuth = tmpCacheDir.appendingPathComponent("no-such-auth.json")
        let provider = XAIProvider(
            credentials: creds,
            grokAuthReader: GrokAuthReader(path: nonExistentAuth),
            cache: cache,
            http: http,
            baseURL: URL(string: "https://management-api.x.ai")!,
            teamId: "",
            preferGrokCLI: true
        )

        do {
            _ = try await provider.fetchUsage(forceRefresh: true)
            Issue.record("expected credentials error")
        } catch let error as AppError {
            expectTrue(error.description.contains("Grok CLI"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        try? FileManager.default.removeItem(at: tmpCacheDir)
        StubURLProtocol.reset()
    }
}
