import Testing
import Foundation
import os.lock
@testable import AiTaskbarApp
import AiTaskbarCore
import AiTaskbarProviders

/// Records every history load: which vendor, and whether it ran on the main
/// thread. The provider closure is synchronous, so `pthread_main_np` reports
/// the thread the load actually ran on.
private final class LoadRecorder: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (counts: [VendorId: Int](), onMain: 0))

    func record(_ vendor: VendorId) {
        let main = pthread_main_np() != 0
        state.withLock {
            $0.counts[vendor, default: 0] += 1
            if main { $0.onMain += 1 }
        }
    }
    func count(_ vendor: VendorId) -> Int { state.withLock { $0.counts[vendor] ?? 0 } }
    var loadsOnMain: Int { state.withLock { $0.onMain } }
    var total: Int { state.withLock { $0.counts.values.reduce(0, +) } }

    var provider: @Sendable (VendorId) -> [UsageHistoryStore.Sample] {
        { [self] vendor in
            record(vendor)
            return [UsageHistoryStore.Sample(at: Date().timeIntervalSince1970, max: 40)]
        }
    }
}

/// PERF-FLU-001 / LEAK-FAN-003: `recompute()` used to decode 90 days of
/// history JSONL per vendor synchronously on the MainActor, twice per cost
/// refresh (and on every other trigger), even with Analytics closed.
@MainActor
@Suite("AnalyticsStore history loading", .serialized)
struct AnalyticsStoreHistoryLoadTests {
    private func settle(_ store: AnalyticsStore) async {
        // Let queued `receive(on: .main)` deliveries run, then await the
        // store's own completion signal: the history load they started.
        await drainMainQueue()
        await store.historyReloadTask?.value
    }

    private func makeStore(_ recorder: LoadRecorder) -> AnalyticsStore {
        AnalyticsStore(
            estimatesProvider: {
                [.anthropic: CostEstimate(usdToday: 1, usdLast7Days: 2),
                 .openai: CostEstimate(usdToday: 3, usdLast7Days: 4)]
            },
            snapshotsProvider: { [:] },
            historyProvider: recorder.provider)
    }

    @Test("history loads run off the main thread")
    func history_load_is_off_main() async {
        let recorder = LoadRecorder()
        let store = makeStore(recorder)
        store.refresh()
        await settle(store)
        #expect(recorder.total > 0)
        #expect(recorder.loadsOnMain == 0)
    }

    @Test("a synchronous burst of recompute triggers loads each vendor once")
    func burst_loads_each_vendor_once() async {
        let recorder = LoadRecorder()
        let store = makeStore(recorder)
        store.refresh()
        store.refresh()
        store.timeframe = .weekly
        await settle(store)
        #expect(recorder.count(.anthropic) == 1)
        #expect(recorder.count(.openai) == 1)
    }

    @Test("loaded histories reach the published snapshot")
    func loaded_history_reaches_snapshot() async {
        let recorder = LoadRecorder()
        let store = makeStore(recorder)
        store.refresh()
        await settle(store)
        let summary = store.snapshot?.vendorSummaries.first { $0.vendor == .anthropic }
        let samples = summary?.usageHistory.count ?? 0
        #expect(samples == 1)
    }

    @Test("one CostEstimator refresh loads each vendor's history at most once")
    func cost_refresh_loads_history_once_per_vendor() async throws {
        let recorder = LoadRecorder()
        let estimator = CostEstimator(
            claudeEstimate: { CostEstimate(usdToday: 1, usdLast7Days: 2) },
            codexEstimate: { CostEstimate(usdToday: 3, usdLast7Days: 4) },
            opencodeScan: { _ in [:] })
        let usage = UsageStore(vendors: [], primary: nil, preferredOrder: [])
        let store = AnalyticsStore(usageStore: usage, costEstimator: estimator,
                                   historyProvider: recorder.provider)
        await settle(store)
        let before = (recorder.count(.anthropic), recorder.count(.openai))

        estimator.refresh(force: true)
        for _ in 0..<400 where estimator.lastComputedAt == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await settle(store)

        #expect(recorder.count(.anthropic) - before.0 <= 1)
        #expect(recorder.count(.openai) - before.1 <= 1)
        #expect(recorder.loadsOnMain == 0)
    }
}
