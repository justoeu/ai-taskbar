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
    private let historyProvider: (VendorId) -> [UsageHistoryStore.Sample]

    public init(
        estimatesProvider: @escaping () -> [VendorId: CostEstimate] = { [:] },
        snapshotsProvider: @escaping () -> [VendorId: VendorSnapshot] = { [:] },
        historyProvider: @escaping (VendorId) -> [UsageHistoryStore.Sample] = { _ in [] },
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
            // subscription; xAI/Z.AI/Gemini totals must not be restated. Models
            // keep a $0 entry so the breakdown still lists them.
            if dict[v] == nil {
                dict[v] = CostEstimate(
                    usdToday: 0,
                    usdLast7Days: 0,
                    modelBreakdownToday: scan.todayByModel.mapValues { _ in 0 },
                    modelBreakdownLast7Days: scan.last7DaysByModel.mapValues { _ in 0 },
                    totalsByModel: scan.last7DaysByModel
                )
            } else if let existing = dict[v] {
                var mergedToday = existing.modelBreakdownToday
                for m in scan.todayByModel.keys where mergedToday[m] == nil {
                    mergedToday[m] = 0
                }
                var mergedLast7 = existing.modelBreakdownLast7Days
                for m in scan.last7DaysByModel.keys where mergedLast7[m] == nil {
                    mergedLast7[m] = 0
                }
                var mergedTotals = existing.totalsByModel
                for (m, u) in scan.last7DaysByModel {
                    CostAggregator.add(u, into: &mergedTotals, model: m)
                }
                dict[v] = CostEstimate(
                    usdToday: existing.usdToday,
                    usdLast7Days: existing.usdLast7Days,
                    modelBreakdownToday: mergedToday,
                    modelBreakdownLast7Days: mergedLast7,
                    totalsByModel: mergedTotals,
                    computedAt: existing.computedAt,
                    isApproximate: existing.isApproximate,
                    note: existing.note
                )
            }
        }
        return dict
    }

    public convenience init(usageStore: UsageStore, costEstimator: CostEstimator) {
        self.init(
            estimatesProvider: { [weak costEstimator, weak usageStore] in
                guard let costEstimator else { return [:] }
                var dict = AnalyticsStore.mergingOpencode(
                    costEstimator.byVendor, opencode: costEstimator.opencode)
                if let usageStore {
                    for v in usageStore.vendors {
                        let vid = v.vendorId
                        if let outcome = v.state.outcome {
                            switch outcome.snapshot {
                            case .openrouter(let s):
                                // totalUsageUSD is lifetime account usage, NOT today/weekly spend.
                                var breakdown: [String: Double] = [:]
                                if let top = s.topModels {
                                    for m in top {
                                        breakdown[m.model] = m.rawUsage
                                    }
                                }
                                let totalFromModels = breakdown.values.reduce(0, +)
                                if totalFromModels > 0 {
                                    let existing = dict[vid]
                                    dict[vid] = CostEstimate(
                                        usdToday: existing?.usdToday ?? 0,
                                        usdLast7Days: totalFromModels,
                                        modelBreakdownToday: existing?.modelBreakdownToday ?? [:],
                                        modelBreakdownLast7Days: breakdown,
                                        totalsByModel: existing?.totalsByModel ?? [:]
                                    )
                                }
                            case .xai(let s):
                                let used = (s.spentUSD ?? 0) + (s.prepaidUsedUSD ?? 0)
                                if used > 0 {
                                    let existing = dict[vid]
                                    dict[vid] = CostEstimate(
                                        usdToday: existing?.usdToday ?? 0,
                                        usdLast7Days: max(existing?.usdLast7Days ?? 0, used),
                                        modelBreakdownToday: existing?.modelBreakdownToday ?? [:],
                                        modelBreakdownLast7Days: existing?.modelBreakdownLast7Days ?? [:],
                                        totalsByModel: existing?.totalsByModel ?? [:]
                                    )
                                }
                            default:
                                break
                            }
                        }
                    }
                }
                return dict
            },
            snapshotsProvider: { [weak usageStore] in
                guard let usageStore else { return [:] }
                var dict: [VendorId: VendorSnapshot] = [:]
                for v in usageStore.vendors {
                    if let outcome = v.state.outcome {
                        dict[v.vendorId] = outcome.snapshot
                    }
                }
                return dict
            },
            historyProvider: { vendor in
                (try? UsageHistoryStore.defaultFor(vendor))?.load(since: Date().addingTimeInterval(-90 * 86_400)) ?? []
            }
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

    private func recompute() {
        isLoading = true
        defer { isLoading = false }

        let estimates = estimatesProvider()
        let snapshots = snapshotsProvider()
        let vendors = Set(estimates.keys).union(snapshots.keys)

        var histories: [VendorId: [UsageHistoryStore.Sample]] = [:]
        for v in vendors {
            histories[v] = historyProvider(v)
        }

        self.snapshot = AnalyticsAggregator.aggregate(
            timeframe: timeframe,
            compareWithPrevious: compareWithPrevious,
            comparisonOffset: comparisonOffset,
            now: Date(),
            histories: histories,
            estimates: estimates,
            snapshots: snapshots
        )
    }

    public func displayIndex(of id: VendorId) -> Int {
        analyticsOrder.firstIndex(of: id) ?? Int.max
    }

    public func moveVendorUp(_ id: VendorId, enabled: [VendorId]) {
        var current = analyticsOrder.filter { enabled.contains($0) }
        for e in enabled where !current.contains(e) {
            current.append(e)
        }
        guard let idx = current.firstIndex(of: id), idx > 0 else { return }
        current.swapAt(idx, idx - 1)
        self.analyticsOrder = current
    }

    public func moveVendorDown(_ id: VendorId, enabled: [VendorId]) {
        var current = analyticsOrder.filter { enabled.contains($0) }
        for e in enabled where !current.contains(e) {
            current.append(e)
        }
        guard let idx = current.firstIndex(of: id), idx < current.count - 1 else { return }
        current.swapAt(idx, idx + 1)
        self.analyticsOrder = current
    }
}
