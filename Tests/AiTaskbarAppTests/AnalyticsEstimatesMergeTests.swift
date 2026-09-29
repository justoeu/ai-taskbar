import Testing
import Foundation
@testable import AiTaskbarApp
import AiTaskbarCore
import AiTaskbarProviders

/// `AnalyticsStore.defaultEstimates` is the real merge behind the Analytics
/// screen's default `estimatesProvider`. Every figure it produces lands in a
/// slot with a fixed window: `usdToday` or `usdLast7Days`. No vendor snapshot
/// carries a rolling 7-day dollar figure — OpenRouter `/api/v1/activity`
/// covers 30 days, xAI spend is billing-cycle-to-date — so none of them may
/// be written into those slots. `defaultEstimates` takes no snapshots at all
/// (VERB-MAE-001), and the contract tests below drive the production
/// `AnalyticsStore(usageStore:costEstimator:)` wiring with real snapshots.
@MainActor
@Suite("AnalyticsEstimatesMerge", .serialized)
struct AnalyticsEstimatesMergeTests {
    private struct NoHistory: Error {}

    private struct FixedSnapshotProvider: UsageProvider {
        let vendorId: VendorId
        let snapshot: VendorSnapshot
        var displayName: String { vendorId.displayName }
        var credentialFileURL: URL? { nil }
        func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
            FetchOutcome(snapshot: snapshot)
        }
    }

    private static let openRouter30Day = VendorSnapshot.openrouter(OpenRouterSnapshot(
        topModels: [
            ModelShare(model: "openai/gpt-4.1", percent: 60, rawUsage: 18),
            ModelShare(model: "google/gemini-2.5-flash", percent: 40, rawUsage: 12)
        ],
        totalUsageUSD: 250))

    private static let xaiCycle = VendorSnapshot.xai(XAISnapshot(
        spentUSD: 40, prepaidUsedUSD: 5, billingCycleLabel: "2026-09"))

    /// Production wiring: vendors in `.ok` with the snapshots above, a cost
    /// estimator whose scanners return `claude` / nothing, Week timeframe.
    private static func weeklySummaries(claude: CostEstimate) async throws -> [VendorId: VendorAnalyticsSummary] {
        let suite = "test-analytics-merge-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vms = [(VendorId.openrouter, openRouter30Day), (.xai, xaiCycle)].map { id, snap in
            VendorViewModel(provider: FixedSnapshotProvider(vendorId: id, snapshot: snap),
                            defaults: defaults, historyStoreFactory: { _ in throw NoHistory() })
        }
        let usage = UsageStore(vendors: vms, primary: nil, preferredOrder: [])
        for vm in vms { vm.refresh(forceRefresh: true) }
        for _ in 0..<400 where vms.contains(where: { $0.state.outcome == nil }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let estimator = CostEstimator(
            claudeEstimate: { claude },
            codexEstimate: { CostEstimate(usdToday: 0, usdLast7Days: 0) },
            opencodeScan: { _ in [:] })
        estimator.refresh(force: true)
        for _ in 0..<400 where estimator.lastComputedAt == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let store = AnalyticsStore(usageStore: usage, costEstimator: estimator,
                                   historyProvider: { _ in [] })
        store.timeframe = .weekly
        store.refresh(force: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        await store.historyReloadTask?.value
        let summaries = store.snapshot?.vendorSummaries ?? []
        return Dictionary(uniqueKeysWithValues: summaries.map { ($0.vendor, $0) })
    }

    private static let claude = CostEstimate(
        usdToday: 2, usdLast7Days: 9,
        modelBreakdownLast7Days: ["claude-opus-5-5": 9],
        computedAt: Date(timeIntervalSince1970: 1_700_000_000))

    @Test("OpenRouter 30-day activity is not Week money in the production wiring")
    func openrouter_activity_not_weekly_cost() async throws {
        let summaries = try await Self.weeklySummaries(claude: Self.claude)
        #expect(summaries[.openrouter]?.totalCostUSD == 0)
    }

    @Test("OpenRouter 30-day activity adds no rows to the Week breakdown")
    func openrouter_activity_adds_no_breakdown_rows() async throws {
        let summaries = try await Self.weeklySummaries(claude: Self.claude)
        #expect(summaries[.openrouter]?.costByModel == [:])
    }

    @Test("xAI billing-cycle spend is not Week money in the production wiring")
    func xai_cycle_spend_not_weekly_cost() async throws {
        let summaries = try await Self.weeklySummaries(claude: Self.claude)
        #expect(summaries[.xai]?.totalCostUSD == 0)
    }

    @Test("the snapshots did reach Analytics (the tests above are not vacuous)")
    func snapshots_reach_analytics() async throws {
        let summaries = try await Self.weeklySummaries(claude: Self.claude)
        #expect(summaries[.openrouter]?.lifetimeCostUSD == 250)
    }

    @Test("scanner estimates reach Week unchanged in the production wiring")
    func scanner_estimates_pass_through_wiring() async throws {
        let summaries = try await Self.weeklySummaries(claude: Self.claude)
        #expect(summaries[.anthropic]?.totalCostUSD == 9)
    }

    @Test("scanner estimates pass through the default merge unchanged")
    func scanner_estimates_pass_through() {
        let merged = AnalyticsStore.defaultEstimates(
            byVendor: [.anthropic: Self.claude], opencode: [:])
        #expect(merged[.anthropic] == Self.claude)
    }

    @Test("the merge adds no vendor that no scanner reported")
    func merge_adds_no_vendor() {
        let merged = AnalyticsStore.defaultEstimates(
            byVendor: [.anthropic: Self.claude], opencode: [:])
        #expect(merged.keys.sorted { $0.rawValue < $1.rawValue } == [.anthropic])
    }

    // MARK: - CQ-MAE-006

    @Test("a history store that cannot be created is reported, not swallowed")
    func history_store_failure_is_reported() {
        var failures: [VendorId] = []
        let samples = AnalyticsStore.diskHistory(
            .kimi, makeStore: { _ in throw NoHistory() },
            onFailure: { vendor, _ in failures.append(vendor) })
        #expect(failures == [.kimi])
        #expect(samples.isEmpty)
    }

    @Test("a working history store is read and nothing is reported")
    func history_store_success_reports_nothing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-analytics-hist-\(UUID().uuidString)")
        try Paths.ensureDir(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageHistoryStore(vendor: .kimi, baseDir: dir)
        store.append(maxUtilization: 42)
        var failures = 0
        let samples = AnalyticsStore.diskHistory(
            .kimi, makeStore: { _ in store }, onFailure: { _, _ in failures += 1 })
        #expect(failures == 0)
        #expect(samples.count == 1)
    }
}
