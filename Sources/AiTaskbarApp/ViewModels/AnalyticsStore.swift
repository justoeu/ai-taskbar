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

    private let estimatesProvider: () -> [VendorId: CostEstimate]
    private let snapshotsProvider: () -> [VendorId: VendorSnapshot]
    private let historyProvider: (VendorId) -> [UsageHistoryStore.Sample]

    public init(
        estimatesProvider: @escaping () -> [VendorId: CostEstimate] = { [:] },
        snapshotsProvider: @escaping () -> [VendorId: VendorSnapshot] = { [:] },
        historyProvider: @escaping (VendorId) -> [UsageHistoryStore.Sample] = { _ in [] }
    ) {
        self.estimatesProvider = estimatesProvider
        self.snapshotsProvider = snapshotsProvider
        self.historyProvider = historyProvider
    }

    public convenience init(usageStore: UsageStore, costEstimator: CostEstimator) {
        self.init(
            estimatesProvider: { [weak costEstimator] in
                guard let costEstimator else { return [:] }
                var dict = costEstimator.byVendor
                for (v, scan) in costEstimator.opencode {
                    if dict[v] == nil {
                        dict[v] = CostEstimate(
                            usdToday: scan.costTodayByModel.values.reduce(0, +),
                            usdLast7Days: scan.costLast7DaysByModel.values.reduce(0, +),
                            modelBreakdownToday: scan.costTodayByModel,
                            modelBreakdownLast7Days: scan.costLast7DaysByModel,
                            totalsByModel: scan.last7DaysByModel
                        )
                    }
                }
                return dict
            },
            snapshotsProvider: { [weak usageStore] in
                guard let usageStore else { return [:] }
                var dict: [VendorId: VendorSnapshot] = [:]
                for v in usageStore.vendors {
                    if case .ok(let outcome) = v.state {
                        dict[v.vendorId] = outcome.snapshot
                    }
                }
                return dict
            },
            historyProvider: { vendor in
                (try? UsageHistoryStore.defaultFor(vendor))?.load(since: Date().addingTimeInterval(-90 * 86_400)) ?? []
            }
        )
    }

    public func refresh() {
        recompute()
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
}
