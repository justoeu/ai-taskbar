import Foundation
import SwiftUI
import Combine
import AiTaskbarCore
import AiTaskbarProviders

@MainActor
public final class AnalyticsStore: ObservableObject {
    @Published public var timeframe: AnalyticsTimeframe = .daily {
        didSet {
            if oldValue != timeframe {
                recompute()
            }
        }
    }

    @Published public var compareWithPrevious: Bool = false {
        didSet {
            if oldValue != compareWithPrevious {
                recompute()
            }
        }
    }

    @Published public var comparisonOffset: Int = 1 {
        didSet {
            if oldValue != comparisonOffset {
                recompute()
            }
        }
    }

    @Published public private(set) var snapshot: GlobalAnalyticsSnapshot?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastRefreshedAt: Date?

    private static let syncOrderDefaultsKey = "sync_vendor_order"
    private static let analyticsOrderDefaultsKey = "analytics_vendor_order"

    private var cancellables = Set<AnyCancellable>()
    private weak var usageStore: UsageStore?
    private weak var costEstimator: CostEstimator?

    /// When true, AnalyticsView follows the home screen's vendor order.
    @Published public var syncVendorOrder: Bool {
        didSet {
            UserDefaults.standard.set(syncVendorOrder, forKey: Self.syncOrderDefaultsKey)
        }
    }

    /// Independent vendor ordering used when `syncVendorOrder == false`.
    @Published public var analyticsOrder: [VendorId] {
        didSet {
            let rawList = analyticsOrder.map(\.rawValue)
            UserDefaults.standard.set(rawList, forKey: Self.analyticsOrderDefaultsKey)
        }
    }

    /// Transient vendor to scroll to and focus when transitioning from the home screen.
    @Published public var targetVendor: VendorId?

    private let estimatesProvider: () -> [VendorId: CostEstimate]
    private let snapshotsProvider: () -> [VendorId: VendorSnapshot]
    private let historyProvider: @Sendable (VendorId) -> [UsageHistoryStore.Sample]
    /// Last histories loaded off the MainActor. `recompute()` aggregates from
    /// these synchronously, so a timeframe switch never waits on disk.
    private var histories: [VendorId: [UsageHistoryStore.Sample]] = [:]
    /// The in-flight off-main history load. Superseded on every trigger, so a
    /// burst of triggers loads each vendor once. Internal so tests can await it.
    private(set) var historyReloadTask: Task<Void, Never>?

    public init(
        estimatesProvider: @escaping () -> [VendorId: CostEstimate] = { [:] },
        snapshotsProvider: @escaping () -> [VendorId: VendorSnapshot] = { [:] },
        historyProvider: @escaping @Sendable (VendorId) -> [UsageHistoryStore.Sample] = { _ in [] },
        defaults: UserDefaults = .standard
    ) {
        self.estimatesProvider = estimatesProvider
        self.snapshotsProvider = snapshotsProvider
        self.historyProvider = historyProvider
        self.syncVendorOrder = defaults.object(forKey: Self.syncOrderDefaultsKey) as? Bool ?? true
        self.analyticsOrder = (defaults.stringArray(forKey: Self.analyticsOrderDefaultsKey) ?? [])
            .compactMap(VendorId.init(rawValue:))
    }

    /// Folds opencode's per-vendor scans into the vendor estimates Analytics
    /// shows. Pure so the default `estimatesProvider` merge is testable.
    nonisolated static func mergingOpencode(
        _ byVendor: [VendorId: CostEstimate],
        opencode: [VendorId: OpencodeScan]
    ) -> [VendorId: CostEstimate] {
        var dict = byVendor
        for (v, scan) in opencode {
            // opencode is a client, not a vendor (see `CostEstimator.opencode`):
            // its tokens are shown, its dollars are never added. OpenAI rides a
            // subscription; xAI/Z.AI/Gemini totals must not be restated. Its
            // models get NO breakdown row either: a $0.00 row would contradict
            // the popover footer, which shows opencode's recorded cost (or its
            // tokens) in a separate section. Only the token totals merge.
            guard let existing = dict[v] else {
                dict[v] = CostEstimate(usdToday: 0, usdLast7Days: 0,
                                       totalsByModel: scan.last7DaysByModel)
                continue
            }
            var mergedTotals = existing.totalsByModel
            for (m, u) in scan.last7DaysByModel {
                CostAggregator.add(u, into: &mergedTotals, model: m)
            }
            dict[v] = CostEstimate(
                usdToday: existing.usdToday,
                usdLast7Days: existing.usdLast7Days,
                modelBreakdownToday: existing.modelBreakdownToday,
                modelBreakdownLast7Days: existing.modelBreakdownLast7Days,
                totalsByModel: mergedTotals,
                computedAt: existing.computedAt,
                isApproximate: existing.isApproximate,
                note: existing.note,
                unpricedModelsToday: existing.unpricedModelsToday,
                unpricedModelsLast7Days: existing.unpricedModelsLast7Days
            )
        }
        return dict
    }

    /// The estimates Analytics shows: the cost scanners' per-vendor totals
    /// with opencode's tokens folded in. Pure and static so the default
    /// `estimatesProvider` is testable without a live `UsageStore` /
    /// `CostEstimator`.
    ///
    /// It takes no snapshots on purpose: **no vendor snapshot contributes
    /// money here.** Every figure lands in a fixed window (`usdToday`,
    /// `usdLast7Days`) and no snapshot carries one: OpenRouter
    /// `/api/v1/activity` covers the last 30 days (no per-item date is
    /// decoded), and xAI `spentUSD` / `prepaidUsedUSD` are
    /// billing-cycle-to-date. Both were once written into `usdLast7Days`; they
    /// stay on the vendor's popover card, which labels their real window.
    nonisolated static func defaultEstimates(
        byVendor: [VendorId: CostEstimate],
        opencode: [VendorId: OpencodeScan]
    ) -> [VendorId: CostEstimate] {
        mergingOpencode(byVendor, opencode: opencode)
    }

    /// Latest good snapshot per vendor, as the popover currently shows it.
    static func currentSnapshots(_ usageStore: UsageStore?) -> [VendorId: VendorSnapshot] {
        guard let usageStore else { return [:] }
        var dict: [VendorId: VendorSnapshot] = [:]
        for v in usageStore.vendors {
            if let outcome = v.state.outcome {
                dict[v.vendorId] = outcome.snapshot
            }
        }
        return dict
    }

    /// Production history source: the vendor's on-disk JSONL, last 90 days.
    public nonisolated static func diskHistory(_ vendor: VendorId) -> [UsageHistoryStore.Sample] {
        diskHistory(vendor, makeStore: UsageHistoryStore.defaultFor, onFailure: logHistoryUnavailable)
    }

    /// Analytics has no history for a vendor whose store cannot be created;
    /// that must be visible in the log, as it is for `VendorViewModel`
    /// (BEST-ATE-006 / CQ-MAE-006), not an empty chart with no reason.
    nonisolated static func diskHistory(
        _ vendor: VendorId,
        makeStore: (VendorId) throws -> UsageHistoryStore,
        onFailure: (VendorId, Error) -> Void
    ) -> [UsageHistoryStore.Sample] {
        do {
            return try makeStore(vendor).load(since: Date().addingTimeInterval(-90 * 86_400))
        } catch {
            onFailure(vendor, error)
            return []
        }
    }

    nonisolated static func logHistoryUnavailable(_ vendor: VendorId, _ error: Error) {
        AppLog.lifecycle.error(
            "analytics history unavailable for \(vendor.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    public convenience init(
        usageStore: UsageStore,
        costEstimator: CostEstimator,
        historyProvider: @escaping @Sendable (VendorId) -> [UsageHistoryStore.Sample] = AnalyticsStore.diskHistory
    ) {
        self.init(
            estimatesProvider: { [weak costEstimator] in
                guard let costEstimator else { return [:] }
                return AnalyticsStore.defaultEstimates(
                    byVendor: costEstimator.byVendor,
                    opencode: costEstimator.opencode)
            },
            snapshotsProvider: { [weak usageStore] in
                AnalyticsStore.currentSnapshots(usageStore)
            },
            historyProvider: historyProvider
        )
        self.usageStore = usageStore
        self.costEstimator = costEstimator

        costEstimator.$byVendor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recompute()
            }
            .store(in: &cancellables)

        usageStore.$vendors
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recompute()
            }
            .store(in: &cancellables)
    }

    public func refresh(force: Bool = false) {
        if force {
            guard !isRefreshing else { return }
            isRefreshing = true
            costEstimator?.refresh(force: true)
            usageStore?.refreshAll(forceRefresh: true)
            recompute()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let self else { return }
                self.recompute()
                self.isRefreshing = false
                self.lastRefreshedAt = Date()
            }
        } else {
            recompute()
            if lastRefreshedAt == nil {
                lastRefreshedAt = Date()
            }
        }
    }

    /// Publishes a snapshot from the in-memory inputs right away, then reloads
    /// the 90-day histories off the MainActor and publishes again when they
    /// land. The load used to run synchronously here, on the MainActor, for
    /// every vendor on every trigger (PERF-FLU-001 / LEAK-FAN-003).
    private func recompute() {
        let vendors = publishSnapshot()
        reloadHistories(for: vendors)
    }

    /// Aggregates from the cached histories. Returns the vendors in scope.
    @discardableResult
    private func publishSnapshot() -> Set<VendorId> {
        let estimates = estimatesProvider()
        let snapshots = snapshotsProvider()
        let vendors = Set(estimates.keys).union(snapshots.keys)
        self.snapshot = AnalyticsAggregator.aggregate(
            timeframe: timeframe,
            compareWithPrevious: compareWithPrevious,
            comparisonOffset: comparisonOffset,
            now: Date(),
            histories: histories.filter { vendors.contains($0.key) },
            estimates: estimates,
            snapshots: snapshots
        )
        return vendors
    }

    private func reloadHistories(for vendors: Set<VendorId>) {
        historyReloadTask?.cancel()
        isLoading = true
        let provider = historyProvider
        historyReloadTask = Task { @MainActor [weak self] in
            // A synchronous burst of triggers cancels this before it runs.
            guard !Task.isCancelled else { return }
            let load = Task.detached(priority: .utility) { () -> [VendorId: [UsageHistoryStore.Sample]]? in
                var loaded: [VendorId: [UsageHistoryStore.Sample]] = [:]
                for vendor in vendors {
                    if Task.isCancelled { return nil }
                    loaded[vendor] = provider(vendor)
                }
                return loaded
            }
            let loaded = await withTaskCancellationHandler {
                await load.value
            } onCancel: {
                load.cancel()
            }
            guard let loaded, !Task.isCancelled, let self else { return }
            self.histories = loaded
            self.isLoading = false
            self.publishSnapshot()
        }
    }

    public func displayIndex(of id: VendorId) -> Int {
        analyticsOrder.firstIndex(of: id) ?? Int.max
    }

    public func moveVendorUp(_ id: VendorId, enabled: [VendorId]) {
        move(id, up: true, enabled: enabled)
    }

    public func moveVendorDown(_ id: VendorId, enabled: [VendorId]) {
        move(id, up: false, enabled: enabled)
    }

    /// A no-op press (either end) writes nothing to UserDefaults.
    private func move(_ id: VendorId, up: Bool, enabled: [VendorId]) {
        let next = VendorOrder.moved(id, up: up, order: analyticsOrder, visible: enabled)
        if next != analyticsOrder { analyticsOrder = next }
    }
}
