import Testing
import Foundation
@testable import AiTaskbarApp
import AiTaskbarCore
import AiTaskbarProviders

@MainActor
@Suite("AnalyticsStore")
struct AnalyticsStoreTests {
    @Test("initializes with default values and nil snapshot")
    func store_initial_state() {
        let store = AnalyticsStore()
        #expect(store.timeframe == .daily)
        #expect(!store.compareWithPrevious)
        #expect(store.snapshot == nil)
        #expect(!store.isLoading)
        expectFalse(store.isRefreshing)
    }

    @Test("force refresh triggers isRefreshing")
    func store_force_refresh() {
        let store = AnalyticsStore()
        expectFalse(store.isRefreshing)
        store.refresh(force: true)
        expectTrue(store.isRefreshing)
    }

    @Test("refresh aggregates inputs into published snapshot")
    func store_refresh() {
        let store = AnalyticsStore(
            estimatesProvider: { () -> [VendorId: CostEstimate] in
                [
                    .anthropic: CostEstimate(usdToday: 15.0, usdLast7Days: 45.0),
                    .openai: CostEstimate(usdToday: 25.0, usdLast7Days: 100.0)
                ]
            },
            snapshotsProvider: { () -> [VendorId: VendorSnapshot] in
                [
                    .anthropic: .anthropic(AnthropicSnapshot(planLabel: "Pro")),
                    .openai: .openai(OpenAISnapshot(planLabel: "Team"))
                ]
            },
            historyProvider: { _ in [] }
        )

        store.refresh()

        let snap = store.snapshot
        #expect(snap != nil)
        #expect(snap?.totalCostUSD == 40.0) // 15 + 25
        #expect(snap?.vendorShares.count == 2)
        #expect(snap?.vendorSummaries.count == 2)
    }

    @Test("switching timeframe triggers recompute")
    func store_timeframe_switch() {
        let store = AnalyticsStore(
            estimatesProvider: { () -> [VendorId: CostEstimate] in
                [
                    .anthropic: CostEstimate(usdToday: 10.0, usdLast7Days: 70.0)
                ]
            },
            snapshotsProvider: { () -> [VendorId: VendorSnapshot] in [:] },
            historyProvider: { _ in [] }
        )

        store.refresh()
        #expect(store.snapshot?.totalCostUSD == 10.0)

        store.timeframe = .weekly
        #expect(store.snapshot?.totalCostUSD == 70.0)
    }

    @Test("syncVendorOrder defaults to true and respects persistence")
    func store_sync_order_behavior() {
        let testDefaults = UserDefaults(suiteName: "AnalyticsStoreTests-\(UUID().uuidString)")!
        let store = AnalyticsStore(defaults: testDefaults)
        expectTrue(store.syncVendorOrder)

        store.syncVendorOrder = false
        expectFalse(store.syncVendorOrder)
        expectFalse(testDefaults.bool(forKey: "sync_vendor_order"))

        store.targetVendor = .anthropic
        #expect(store.targetVendor == .anthropic)
    }

    @Test("analyticsOrder reorders independently when sync is false")
    func store_analytics_order_reorder() {
        let testDefaults = UserDefaults(suiteName: "AnalyticsStoreTests-\(UUID().uuidString)")!
        let store = AnalyticsStore(defaults: testDefaults)
        let enabled: [VendorId] = [.anthropic, .openai, .gemini]

        store.analyticsOrder = enabled
        #expect(store.displayIndex(of: .anthropic) == 0)
        #expect(store.displayIndex(of: .openai) == 1)

        store.moveVendorDown(.anthropic, enabled: enabled)
        #expect(store.analyticsOrder == [.openai, .anthropic, .gemini])
        #expect(store.displayIndex(of: .anthropic) == 1)

        store.moveVendorUp(.anthropic, enabled: enabled)
        #expect(store.analyticsOrder == [.anthropic, .openai, .gemini])
    }
}
