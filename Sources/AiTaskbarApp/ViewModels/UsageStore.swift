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
    /// Wall-clock instant the scheduler last fired a tick (regardless of
    /// whether each vendor's fetch ultimately succeeded). Drives the
    /// header countdown — basing the countdown on `lastRefreshedAt`
    /// (which only advances on truly fresh data) would freeze it at 0:00
    /// every time a scheduled tick lands inside the cache TTL window or
    /// the network 429s into the stale fallback path.
    @Published public private(set) var lastScheduledTickAt: Date?

    public let thresholds: ThresholdsConfig
    /// Configured scheduler cadence in seconds — surfaced here so views can
    /// render a forward countdown ("Próx. em 4:59") without having to depend
    /// on RefreshScheduler directly. Kept as a constant: changes to
    /// `refresh_interval_seconds` in config.toml require a relaunch to take
    /// effect (same as RefreshScheduler itself), so a `let` is honest.
    public let refreshIntervalSeconds: TimeInterval
    private var subscriptions: Set<AnyCancellable> = []

    public init(vendors: [VendorViewModel],
                primary: VendorId?,
                thresholds: ThresholdsConfig = .init(),
                refreshIntervalSeconds: TimeInterval = 300) {
        self.vendors = vendors
        self.primary = primary
        self.thresholds = thresholds
        self.refreshIntervalSeconds = refreshIntervalSeconds
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

    /// Stamp the scheduler tick that's about to dispatch fetches. The view
    /// reads `lastScheduledTickAt` to anchor the countdown.
    public func markScheduledTick() {
        lastScheduledTickAt = .now
    }

    /// True when at least one vendor is mid-fetch. Views use this to swap
    /// the "Próx. em M:SS" countdown for an "Atualizando…" label while the
    /// scheduler's tick is in flight.
    public var isAnyVendorLoading: Bool {
        vendors.contains { vm in
            if case .loading = vm.state { return true }
            return false
        }
    }

    /// True if any vendor's most recent refresh ended in HTTP 429 — whether
    /// surfaced directly as `.failed(429, _)` OR masked as a stale-fallback
    /// `.ok(outcome)` whose `outcome.lastError?.status == 429`. CachedFetch
    /// converts a 429 into a stale-`.ok` whenever any cached payload exists
    /// (<7-day maxStale), so checking only `.failed` would miss the steady-
    /// state case and let RefreshScheduler's back-off branch sit idle.
    public var hasRateLimitedVendor: Bool {
        vendors.contains { vm in
            switch vm.state {
            case .failed(let err, let fallback):
                if err.isRateLimited { return true }
                return fallback?.lastError?.status == 429
            case .ok(let outcome):
                return outcome.lastError?.status == 429
            case .idle, .loading:
                return false
            }
        }
    }

    public func refresh(vendor: VendorId, forceRefresh: Bool = true) {
        vendorVM(vendor)?.refresh(forceRefresh: forceRefresh)
    }

    public func compactAllHistory() {
        for v in vendors { v.compactHistory() }
    }
}
