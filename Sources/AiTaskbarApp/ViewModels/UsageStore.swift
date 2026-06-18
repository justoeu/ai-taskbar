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
    /// Wall-clock instant the scheduler last fired a tick (regardless of
    /// whether each vendor's fetch ultimately succeeded). Drives the
    /// header countdown — basing the countdown on the per-vendor
    /// `lastNetworkFetch` (which only advances on truly fresh data) would
    /// freeze it at 0:00 every time a scheduled tick lands inside the
    /// cache TTL window or the network 429s into the stale fallback path.
    @Published public private(set) var lastScheduledTickAt: Date?
    /// True when at least one vendor is mid-fetch. Pre-computed so the
    /// 1-Hz countdown TimelineView reads it as a flat property instead of
    /// re-running a 6-element enum scan every second.
    @Published public private(set) var isAnyVendorLoading: Bool = false
    /// True if any vendor's most recent refresh ended in HTTP 429 — whether
    /// surfaced directly as `.failed(429, _)` OR masked as a stale-fallback
    /// `.ok(outcome)` whose `outcome.lastError?.status == 429`. CachedFetch
    /// converts a 429 into a stale-`.ok` whenever any cached payload exists
    /// (<7-day maxStale), so checking only `.failed` would miss the
    /// steady-state case and let `RefreshScheduler`'s back-off branch sit
    /// idle. Pre-computed in `recomputeAggregates`.
    @Published public private(set) var hasRateLimitedVendor: Bool = false

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

    /// Merge every vendor's `$state` publisher into one stream, throttle
    /// the result to coalesce bursts (each `VendorViewModel.refresh()`
    /// fires `.loading` → `.ok/.failed` synchronously in quick succession),
    /// then recompute the cross-vendor aggregates exactly once per burst.
    ///
    /// Why we no longer subscribe to `$lastNetworkFetch`: it used to feed
    /// `lastRefreshedAt`, but no view consumes that anymore (the header
    /// countdown anchors on `lastScheduledTickAt`). Dropping the
    /// subscription halves the publisher fan-out per refresh cycle.
    private func wireUpAggregates() {
        subscriptions.removeAll()
        let stateStreams = vendors.map { $0.$state.eraseToAnyPublisher() }
        Publishers.MergeMany(stateStreams)
            .throttle(for: .milliseconds(50),
                      scheduler: RunLoop.main,
                      latest: true)
            .sink { [weak self] _ in self?.recomputeAggregates() }
            .store(in: &subscriptions)
        recomputeAggregates()
    }

    private func recomputeAggregates() {
        let result = AggregatesComputation.compute(states: vendors.map(\.state))
        if result.maxUtilization != maxUtilization { maxUtilization = result.maxUtilization }
        if result.isAnyVendorLoading != isAnyVendorLoading { isAnyVendorLoading = result.isAnyVendorLoading }
        if result.hasRateLimitedVendor != hasRateLimitedVendor { hasRateLimitedVendor = result.hasRateLimitedVendor }
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

    /// True while RefreshScheduler is sleeping out the extra
    /// `rateLimitBackoff` after a 429 — used by the countdown label to
    /// show "Aguardando rate-limit…" instead of freezing at 0:00.
    @Published public private(set) var isInRateLimitBackoff: Bool = false

    public func enterRateLimitBackoff() {
        if !isInRateLimitBackoff { isInRateLimitBackoff = true }
    }
    public func exitRateLimitBackoff() {
        if isInRateLimitBackoff { isInRateLimitBackoff = false }
    }

    public func refresh(vendor: VendorId, forceRefresh: Bool = true) {
        vendorVM(vendor)?.refresh(forceRefresh: forceRefresh)
    }

    public func compactAllHistory() {
        for v in vendors { v.compactHistory() }
    }

    /// Schedules a history compaction off the MainActor. The history stores
    /// are `@unchecked Sendable` with internal `NSLock` serialization, so
    /// `compact()` is safe to invoke from a background task. Use this from
    /// `RefreshScheduler` so launch-time compaction (6 vendors × up to
    /// ~300 KB JSONL) doesn't block the UI for 100–500 ms.
    public func compactAllHistoryDetached() {
        let stores = vendors.compactMap { $0.historyStore }
        guard !stores.isEmpty else { return }
        Task.detached(priority: .utility) {
            for store in stores { store.compact() }
        }
    }
}

/// Pure aggregation logic extracted from `UsageStore.recomputeAggregates()`.
/// Computes the cross-vendor `maxUtilization` / `isAnyVendorLoading` /
/// `hasRateLimitedVendor` flags from a list of per-vendor states. Exposed so
/// the subtle `hasRateLimitedVendor` invariant — which must fire on BOTH
/// `.failed(429, _)` AND stale-`.ok(outcome)` whose `outcome.lastError?.status
/// == 429` (CachedFetch converts a 429 into a stale `.ok` whenever a cached
/// payload exists) — can be unit-tested without standing up the full store.
@MainActor
public enum AggregatesComputation {
    public struct Result: Equatable {
        public let maxUtilization: Double
        public let isAnyVendorLoading: Bool
        public let hasRateLimitedVendor: Bool

        public init(maxUtilization: Double,
                    isAnyVendorLoading: Bool,
                    hasRateLimitedVendor: Bool) {
            self.maxUtilization = maxUtilization
            self.isAnyVendorLoading = isAnyVendorLoading
            self.hasRateLimitedVendor = hasRateLimitedVendor
        }
    }

    public static func compute(states: [VendorViewModel.State]) -> Result {
        var maxUtil = 0.0
        var loading = false
        var rateLimited = false
        // Single pass so the steady-state cost is O(vendors), not 2×.
        for state in states {
            switch state {
            case .idle:
                break
            case .loading:
                loading = true
                if let m = state.outcome?.snapshot.maxUtilization, m > maxUtil {
                    maxUtil = m
                }
            case .ok(let outcome):
                if outcome.lastError?.status == 429 { rateLimited = true }
                let m = outcome.snapshot.maxUtilization
                if m > maxUtil { maxUtil = m }
            case .failed(let err, let fallback):
                if err.isRateLimited || fallback?.lastError?.status == 429 {
                    rateLimited = true
                }
                if let m = fallback?.snapshot.maxUtilization, m > maxUtil {
                    maxUtil = m
                }
            }
        }
        return Result(maxUtilization: maxUtil,
                      isAnyVendorLoading: loading,
                      hasRateLimitedVendor: rateLimited)
    }
}
