import Foundation
import SwiftUI
import Combine
import AiTaskbarCore
import AiTaskbarProviders

/// Coordinator across the per-vendor ViewModels. Holds shared config
/// (thresholds, primary vendor) and a derived `maxUtilization` that
/// drives the menu-bar icon.
///
/// **Why not a `[VendorId: ProviderState]` here:** that dict made every
/// per-vendor update invalidate the whole store, fanning out re-renders to
/// all `VendorSectionView`s. Per-vendor `VendorViewModel`s plus a Combine
/// subscription that recomputes `maxUtilization` keep the menu bar reactive
/// without rebuilding sections that didn't change.
@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var vendors: [VendorViewModel]
    @Published public var primary: VendorId?
    @Published public private(set) var maxUtilization: Double = 0
    @Published public private(set) var lastRefreshedAt: Date?

    public let thresholds: ThresholdsConfig
    private var subscriptions: Set<AnyCancellable> = []

    public init(vendors: [VendorViewModel],
                primary: VendorId?,
                thresholds: ThresholdsConfig = .init()) {
        self.vendors = vendors
        self.primary = primary
        self.thresholds = thresholds
        wireUpAggregates()
    }

    /// Subscribe to each VendorViewModel's `state` and `lastNetworkFetch`
    /// publishers. On every change, recompute the cross-vendor aggregates.
    /// `removeDuplicates()` on the resulting Double / Date dampens redundant
    /// `objectWillChange.send()` calls — the MenuBarLabelView only re-renders
    /// when the global max actually changes value.
    private func wireUpAggregates() {
        subscriptions.removeAll()
        for vm in vendors {
            vm.$state
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.recomputeAggregates() }
                .store(in: &subscriptions)
            vm.$lastNetworkFetch
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.recomputeAggregates() }
                .store(in: &subscriptions)
        }
        recomputeAggregates()
    }

    private func recomputeAggregates() {
        let newMax = vendors.compactMap { $0.state.outcome?.snapshot.maxUtilization }.max() ?? 0
        if newMax != maxUtilization { maxUtilization = newMax }

        let newest = vendors.compactMap { $0.lastNetworkFetch }.max()
        if newest != lastRefreshedAt { lastRefreshedAt = newest }
    }

    // MARK: - Public surface used by views

    public var providerIds: [VendorId] { vendors.map(\.vendorId) }
    public var providers: [any UsageProvider] { vendors.map(\.provider) }

    public func vendorVM(_ id: VendorId) -> VendorViewModel? {
        vendors.first(where: { $0.vendorId == id })
    }

    public func refreshAll(forceRefresh: Bool = false) {
        for v in vendors { v.refresh(forceRefresh: forceRefresh) }
    }

    public func refresh(vendor: VendorId, forceRefresh: Bool = true) {
        vendorVM(vendor)?.refresh(forceRefresh: forceRefresh)
    }

    public func compactAllHistory() {
        for v in vendors { v.compactHistory() }
    }
}
