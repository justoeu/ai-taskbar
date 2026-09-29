import Foundation
import SwiftUI
import AiTaskbarCore

@MainActor
public final class RefreshScheduler: ObservableObject {
    public let interval: TimeInterval
    public let statusInterval: TimeInterval
    /// Extra delay applied to the next sleep when the previous cycle saw any
    /// HTTP 429. Stacked on top of `interval` so a rate-limited vendor gets a
    /// 6-minute breather (default 300 + 60) before being polled again.
    public static let rateLimitBackoff: TimeInterval = 60
    private weak var store: UsageStore?
    private weak var statusStore: ServiceStatusStore?
    private weak var costEstimator: CostEstimator?
    private weak var updates: UpdateChecker?
    private var refreshLoop: Task<Void, Never>?
    private var statusRefreshLoop: Task<Void, Never>?
    private var compactLoop: Task<Void, Never>?
    private var updateCheckLoop: Task<Void, Never>?
    /// Suspends the usage refresh loop between ticks. Production uses
    /// `Task.sleep`; tests inject a scripted sleeper so the cadence and the
    /// 429 back-off can be asserted without wall-clock waits. Returning early
    /// on cancellation is fine: the loop re-checks `Task.isCancelled`.
    typealias Sleeper = @MainActor (TimeInterval) async -> Void
    private let sleeper: Sleeper
    /// The time a tick is dispatched at, which bounds how long a hung fetch
    /// is skipped (`UsageStore.maxInFlightAge`). Tests advance it with the
    /// scripted sleeper instead of waiting on the wall clock.
    typealias Clock = @MainActor () -> Date
    private let clock: Clock

    static func taskSleep(_ seconds: TimeInterval) async {
        // Best-effort: a cancelled sleep simply returns and the loop's own
        // `Task.isCancelled` check ends it.
        try? await Task.sleep(for: .seconds(seconds))
    }

    public convenience init(store: UsageStore,
                            statusStore: ServiceStatusStore? = nil,
                            costEstimator: CostEstimator? = nil,
                            updates: UpdateChecker? = nil,
                            interval: TimeInterval = 300) {
        self.init(store: store, statusStore: statusStore, costEstimator: costEstimator, updates: updates, interval: interval,
                  minimumInterval: 15, minimumStatusInterval: 300)
    }

    init(store: UsageStore,
         statusStore: ServiceStatusStore?,
         costEstimator: CostEstimator? = nil,
         updates: UpdateChecker? = nil,
         interval: TimeInterval,
         minimumInterval: TimeInterval,
         minimumStatusInterval: TimeInterval,
         sleeper: @escaping Sleeper = RefreshScheduler.taskSleep,
         clock: @escaping Clock = { .now }) {
        self.store = store
        self.sleeper = sleeper
        self.clock = clock
        self.statusStore = statusStore
        self.costEstimator = costEstimator
        self.updates = updates
        // Floor at 15 s. Below this the undocumented vendor endpoints
        // (Anthropic, Codex, Z.AI) start returning 429 aggressively.
        self.interval = max(minimumInterval, interval)
        self.statusInterval = max(minimumStatusInterval, self.interval)
    }

    /// Idempotent: subsequent calls (e.g. on every popover open) are no-ops so
    /// we don't reset the recurring cycle.
    public func start() {
        startRefreshLoop()
        startStatusRefreshLoop()
        startCompactLoop()
        startUpdateCheckLoop()
    }

    /// A separate cadence prevents usage 429 back-off or a hung credential
    /// fetch from delaying public status. The scheduler still owns every
    /// long-lived timer; status and usage merely have independent loops.
    private func startStatusRefreshLoop() {
        guard statusRefreshLoop == nil, statusStore != nil else { return }
        let seconds = statusInterval
        // Every loop re-reads `self` weakly per step and never holds it
        // across a sleep, so dropping the scheduler lets deinit cancel the
        // loops (LEAK-FAN-008).
        statusRefreshLoop = Task { @MainActor [weak self] in
            await Self.refreshStatus(self?.statusStore)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { break }
                await Self.refreshStatus(self?.statusStore)
            }
        }
    }

    private static func refreshStatus(_ statusStore: ServiceStatusStore?) async {
        guard let statusStore else { return }
        statusStore.refreshAll(forceRefresh: false)
        await statusStore.waitForCurrentRefresh()
    }

    private func startRefreshLoop() {
        guard refreshLoop == nil else { return }
        let sleeper = self.sleeper
        let interval = self.interval
        refreshLoop = Task { @MainActor [weak self] in
            // Initial fetch keeps cache semantics — if a relaunch lands
            // inside a fresh cache window, don't burn a network call.
            self?.dispatchScheduledTick()
            while !Task.isCancelled {
                // Sleep the configured interval first. While we sleep, the
                // previous cycle's async per-vendor Tasks complete and
                // update their state. Only AFTER waking do we sample
                // `hasRateLimitedVendor`, because if we sampled before the
                // sleep the state we'd read is the synchronous `.loading`
                // that `refreshIdleVendors` just set — wiping any `.failed(429)`
                // or stale-`.ok(429-lastError)` from the cycle we're
                // trying to back off from.
                await sleeper(interval)
                if Task.isCancelled { break }
                if self?.store?.hasRateLimitedVendor ?? false {
                    // Surface the back-off to the UI so the countdown
                    // label can render "Aguardando rate-limit…" instead
                    // of freezing at 0:00 for 60 s. Cleared right before
                    // the markScheduledTick that follows so the countdown
                    // re-anchors cleanly.
                    self?.store?.enterRateLimitBackoff()
                    await sleeper(Self.rateLimitBackoff)
                    self?.store?.exitRateLimitBackoff()
                    if Task.isCancelled { break }
                }
                self?.dispatchScheduledTick()
            }
        }
    }

    /// One scheduled fan-out, with `forceRefresh: false`. AppEnvironment
    /// wires the DiskCache TTL to `max(15, interval - 5)` and ticks are
    /// dispatched `interval` apart (plus any 429 back-off), measured from
    /// dispatch, not from completion. So a fetch that completed within ~5 s
    /// of its dispatch left a cache entry that is already expired at the
    /// next tick, and CachedFetch goes to the network. A slower fetch wrote
    /// its entry later: the next tick may still land inside the TTL and
    /// serve that payload (at most one interval old) from cache; the tick
    /// after that refetches.
    ///
    /// Single-flight per vendor: a vendor whose previous fetch is still in
    /// flight is skipped (BP-HYD-005) while every other vendor refreshes, so
    /// one hung fetch cannot stall the whole cycle (RACE-CRO-003), until the
    /// fetch is `UsageStore.maxInFlightAge` old; then this tick supersedes it
    /// (RACE-MAE-001). Cancel-on-supersede in VendorViewModel covers manual
    /// refreshes.
    private func dispatchScheduledTick() {
        guard let store else { return }
        store.markScheduledTick()
        store.refreshIdleVendors(forceRefresh: false, now: clock())
        costEstimator?.refresh()
    }

    private func startCompactLoop() {
        guard compactLoop == nil else { return }
        compactLoop = Task { @MainActor [weak self] in
            // Compact once at startup so JSONL files trimmed on launch, then
            // every 24 h thereafter. Without this the history files grow
            // ~300 KB/day per vendor unbounded.
            //
            // Dispatched off-MainActor via `compactAllHistoryDetached()`:
            // the I/O (mmap, decode-each-line, atomic rewrite) for 6 vendors
            // at launch takes 100–500 ms on cold cache, which would otherwise
            // freeze the popover on first open.
            self?.store?.compactAllHistoryDetached()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                if Task.isCancelled { break }
                self?.store?.compactAllHistoryDetached()
            }
        }
    }

    private func startUpdateCheckLoop() {
        guard updateCheckLoop == nil, updates != nil else { return }
        updateCheckLoop = Task { @MainActor [weak self] in
            self?.updates?.checkIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86_400))
                if Task.isCancelled { break }
                self?.updates?.checkIfNeeded()
            }
        }
    }

    public func stop() {
        refreshLoop?.cancel()
        statusRefreshLoop?.cancel()
        compactLoop?.cancel()
        updateCheckLoop?.cancel()
        refreshLoop = nil
        statusRefreshLoop = nil
        compactLoop = nil
        updateCheckLoop = nil
    }

    deinit {
        refreshLoop?.cancel()
        statusRefreshLoop?.cancel()
        compactLoop?.cancel()
        updateCheckLoop?.cancel()
    }
}
