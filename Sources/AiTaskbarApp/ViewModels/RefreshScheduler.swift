import Foundation
import SwiftUI
import AiTaskbarCore

@MainActor
public final class RefreshScheduler: ObservableObject {
    public let interval: TimeInterval
    /// Extra delay applied to the next sleep when the previous cycle saw any
    /// HTTP 429. Stacked on top of `interval` so a rate-limited vendor gets a
    /// 6-minute breather (default 300 + 60) before being polled again.
    public static let rateLimitBackoff: TimeInterval = 60
    private weak var store: UsageStore?
    private var refreshLoop: Task<Void, Never>?
    private var compactLoop: Task<Void, Never>?

    public init(store: UsageStore, interval: TimeInterval = 300) {
        self.store = store
        // Floor at 15 s. Below this the undocumented vendor endpoints
        // (Anthropic, Codex, Z.AI) start returning 429 aggressively.
        self.interval = max(15, interval)
    }

    /// Idempotent: subsequent calls (e.g. on every popover open) are no-ops so
    /// we don't reset the recurring cycle or re-stamp `lastRefreshedAt`.
    public func start() {
        startRefreshLoop()
        startCompactLoop()
    }

    private func startRefreshLoop() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { @MainActor [weak self] in
            guard let self else { return }
            // Initial fetch so the popover isn't blank on first open.
            self.store?.refreshAll(forceRefresh: false)
            while !Task.isCancelled {
                // Sleep the configured interval first. While we sleep, the
                // previous cycle's async per-vendor Tasks complete and update
                // their state. Only AFTER waking do we sample
                // `hasRateLimitedVendor`, because if we sampled before the
                // sleep the state we'd read is the synchronous `.loading`
                // that `refreshAll` just set — wiping any `.failed(429)` or
                // stale-`.ok(429-lastError)` from the cycle we're trying to
                // back off from.
                try? await Task.sleep(for: .seconds(self.interval))
                if Task.isCancelled { break }
                if self.store?.hasRateLimitedVendor ?? false {
                    try? await Task.sleep(for: .seconds(Self.rateLimitBackoff))
                    if Task.isCancelled { break }
                }
                self.store?.refreshAll(forceRefresh: false)
            }
        }
    }

    private func startCompactLoop() {
        guard compactLoop == nil else { return }
        compactLoop = Task { @MainActor [weak self] in
            // Compact once at startup so JSONL files trimmed on launch, then
            // every 24 h thereafter. Without this the history files grow
            // ~300 KB/day per vendor unbounded.
            self?.store?.compactAllHistory()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                if Task.isCancelled { break }
                self?.store?.compactAllHistory()
            }
        }
    }

    public func stop() {
        refreshLoop?.cancel()
        compactLoop?.cancel()
        refreshLoop = nil
        compactLoop = nil
    }

    deinit {
        refreshLoop?.cancel()
        compactLoop?.cancel()
    }
}
