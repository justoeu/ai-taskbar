import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// The credits progress bar only works if the provider actually folds each
/// observed balance into the persisted baseline and hands the denominator
/// back to the snapshot. These drive that wiring end to end.
@Suite("OpenAIProvider — credits baseline wiring", .serialized)
final class OpenAICreditsProviderTests {
    let tmpDir: URL

    init() throws {
        StubURLProtocol.reset()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-credits-e2e-\(UUID().uuidString)")
        try Paths.ensureDir(tmpDir)
    }

    // One instance per @Test: clean up so runs do not pile up in TMPDIR, and
    // clear the process-wide stub here rather than at the end of each test —
    // a trailing reset is skipped whenever an assertion above it throws.
    deinit {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Local base64url so this suite does not depend on another file's
    /// fileprivate helper.
    private func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func authFile() throws -> FileCredentialReader {
        let header = base64URL("{\"alg\":\"none\"}")
        let exp = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let payload = base64URL("{\"exp\":\(exp)}")
        let url = tmpDir.appendingPathComponent("auth.json")
        try #"""
        {"tokens":{"access_token":"a","refresh_token":"r","id_token":"\#(header).\#(payload)."}}
        """#.write(to: url, atomically: true, encoding: .utf8)
        return FileCredentialReader(path: url)
    }

    private func provider(baseline: CreditBaselineStore?) throws -> OpenAIProvider {
        OpenAIProvider(credentials: try authFile(),
                       cache: DiskCache(vendor: .openai, baseDir: tmpDir),
                       http: HTTPClient.stubbed(protocols: [StubURLProtocol.self]),
                       creditBaseline: baseline)
    }

    private func credits(from outcome: FetchOutcome) throws -> OpenAICreditsInfo {
        guard case let .openai(snap) = outcome.snapshot else {
            Issue.record("expected an openai snapshot")
            throw AppError.schema("wrong vendor")
        }
        return try #require(snap.credits)
    }

    @Test("the real credit payload parses as a quantity and reports credit funding")
    func real_payload_is_a_quantity() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.openaiCreditsFunding200))
        }
        let store = CreditBaselineStore(vendor: .openai, baseDir: tmpDir)
        let info = try credits(from: try await provider(baseline: store)
            .fetchUsage(forceRefresh: true))

        #expect(info.balance == 4890.316252)
        #expect(info.localMessages == CreditMessageRange(low: 1223, high: 6357))
        #expect(info.cloudMessages == CreditMessageRange(low: 196, high: 1223))
        #expect(info.isFundingRequests)
        #expect(!info.overageLimitReached)
        // The first sighting seeds the baseline, and a peak equal to the
        // balance says nothing — so no bar, rather than a green 0% claiming
        // the user has spent nothing.
        #expect(info.peakBalance == 4890.316252)
        expectTrue(info.consumedPercent == nil)
        expectTrue(!info.requestsBlocked)
    }

    @Test("a later, smaller balance advances the bar against the seeded baseline")
    func bar_advances_as_credits_drain() async throws {
        let store = CreditBaselineStore(vendor: .openai, baseDir: tmpDir)
        // Seed as if the app had been watching since the credits were bought.
        _ = store.recordAndPeak(balance: 5000)

        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.openaiCreditsFunding200))
        }
        let info = try credits(from: try await provider(baseline: store)
            .fetchUsage(forceRefresh: true))
        #expect(info.peakBalance == 5000)
        // 4890.316252 left of 5000 => 2.19% consumed.
        let percent = try #require(info.consumedPercent)
        #expect((percent * 100).rounded() == 219)
    }

    @Test("unmetered credits never touch the baseline store and draw no bar")
    func unlimited_skips_baseline() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.openaiCreditsUnlimited200))
        }
        let store = CreditBaselineStore(vendor: .openai, baseDir: tmpDir)
        let info = try credits(from: try await provider(baseline: store)
            .fetchUsage(forceRefresh: true))

        #expect(info.isUnlimited)
        expectTrue(info.consumedPercent == nil)
        expectTrue(store.load() == nil)
        expectTrue(!info.isFundingRequests)
    }

    @Test("without a baseline store the balance still shows, just without a bar")
    func no_store_still_reports_balance() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.openaiCreditsFunding200))
        }
        let info = try credits(from: try await provider(baseline: nil)
            .fetchUsage(forceRefresh: true))
        #expect(info.balance == 4890.316252)
        expectTrue(info.peakBalance == nil)
        expectTrue(info.consumedPercent == nil)
    }
}
