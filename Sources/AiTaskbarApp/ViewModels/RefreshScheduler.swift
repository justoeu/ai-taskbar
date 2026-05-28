import Foundation
import SwiftUI
import AiTaskbarCore

@MainActor
public final class RefreshScheduler: ObservableObject {
    public let interval: TimeInterval
    private weak var store: UsageStore?
    private var refreshLoop: Task<Void, Never>?
    private var compactLoop: Task<Void, Never>?

    public init(store: UsageStore, interval: TimeInterval = 150) {
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
                try? await Task.sleep(for: .seconds(self.interval))
                if Task.isCancelled { break }
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
