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

    public convenience init(usageStore: UsageStore, costEstimator: CostEstimator) {
        self.init(
            estimatesProvider: { [weak costEstimator, weak usageStore] in
                guard let costEstimator else { return [:] }
                var dict = costEstimator.byVendor
                for (v, scan) in costEstimator.opencode {
                    let table = PricingTable.table(for: v)
                    var computedToday: [String: Double] = [:]
                    for (model, usage) in scan.todayByModel {
                        let existingCost = scan.costTodayByModel[model] ?? 0
                        if existingCost > 0 {
                            computedToday[model] = existingCost
                        } else if let pricing = PricingTable.lookup(model, table: table) {
                            computedToday[model] = CostMath.cost(usage: usage, pricing: pricing)
                        } else {
                            computedToday[model] = 0
                        }
                    }

                    var computedLast7: [String: Double] = [:]
                    for (model, usage) in scan.last7DaysByModel {
                        let existingCost = scan.costLast7DaysByModel[model] ?? 0
                        if existingCost > 0 {
                            computedLast7[model] = existingCost
                        } else if let pricing = PricingTable.lookup(model, table: table) {
                            computedLast7[model] = CostMath.cost(usage: usage, pricing: pricing)
                        } else {
                            computedLast7[model] = 0
                        }
                    }

                    let sumToday = computedToday.values.reduce(0, +)
                    let sumLast7 = computedLast7.values.reduce(0, +)

                    if dict[v] == nil {
                        dict[v] = CostEstimate(
                            usdToday: sumToday,
                            usdLast7Days: sumLast7,
                            modelBreakdownToday: computedToday,
                            modelBreakdownLast7Days: computedLast7,
                            totalsByModel: scan.last7DaysByModel
                        )
                    } else if let existing = dict[v] {
                        var mergedToday = existing.modelBreakdownToday
                        for (m, c) in computedToday {
                            mergedToday[m, default: 0] += c
                        }
                        var mergedLast7 = existing.modelBreakdownLast7Days
                        for (m, c) in computedLast7 {
                            mergedLast7[m, default: 0] += c
                        }
                        var mergedTotals = existing.totalsByModel
                        for (m, u) in scan.last7DaysByModel {
                            CostAggregator.add(u, into: &mergedTotals, model: m)
                        }
                        dict[v] = CostEstimate(
                            usdToday: existing.usdToday + sumToday,
                            usdLast7Days: existing.usdLast7Days + sumLast7,
                            modelBreakdownToday: mergedToday,
                            modelBreakdownLast7Days: mergedLast7,
                            totalsByModel: mergedTotals,
                            computedAt: existing.computedAt,
                            isApproximate: existing.isApproximate,
                            note: existing.note
                        )
                    }
                }
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
