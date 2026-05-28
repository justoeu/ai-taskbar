import Foundation
import SwiftUI
import Combine
import AiTaskbarCore
import AiTaskbarProviders

/// One ObservableObject per vendor section. Splitting state per-vendor means
/// a Claude refresh only re-renders the Claude section — not the OpenAI/Z.AI/
/// OpenRouter/Kimi sections. (Previously a single `UsageStore.@Published states`
/// dict fanned out invalidations to every `VendorSectionView`.)
@MainActor
public final class VendorViewModel: ObservableObject, Identifiable {
    public enum State: Equatable {
        case idle
        case loading
        case ok(FetchOutcome)
        case failed(error: AppError, fallback: FetchOutcome?)

        public var outcome: FetchOutcome? {
            switch self {
            case .ok(let o): return o
            case .failed(_, let o): return o
            default: return nil
            }
        }
    }

    // `id` is nonisolated because the underlying `vendorId` is a `let` and
    // `Identifiable` requirement is itself nonisolated. Silences a Swift 6
    // strict-concurrency conformance warning.
    public nonisolated var id: VendorId { vendorId }
    public nonisolated let vendorId: VendorId
    public let provider: any UsageProvider

    @Published public private(set) var state: State = .idle
    @Published public private(set) var history: [UsageHistoryStore.Sample] = []
    @Published public private(set) var lastNetworkFetch: Date?

    public let historyStore: UsageHistoryStore?
    private weak var notifications: NotificationService?
    /// Bumped on every refresh — used to track in-flight task ownership
    /// without racing on Task identity.
    private var epoch: Int = 0

    public init(provider: any UsageProvider,
                notifications: NotificationService? = nil) {
        self.vendorId = provider.vendorId
        self.provider = provider
        self.notifications = notifications
        self.historyStore = try? UsageHistoryStore.defaultFor(provider.vendorId)
        if let store = historyStore {
            self.history = store.load(since: Date.now.addingTimeInterval(-24 * 3600))
        }
    }

    public func refresh(forceRefresh: Bool) {
        epoch += 1
        let myEpoch = epoch
        state = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.provider.fetchUsage(forceRefresh: forceRefresh)
                if Task.isCancelled { return }
                guard myEpoch == self.epoch else { return }   // newer refresh wins
                self.state = .ok(outcome)
                if (outcome.cacheAge ?? .greatestFiniteMagnitude) <= 1 {
                    self.lastNetworkFetch = .now
                }
                self.notifications?.observe(vendor: self.vendorId, snapshot: outcome.snapshot)
                self.recordHistory(outcome.snapshot.maxUtilization)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                guard myEpoch == self.epoch else { return }
                let appErr = AppError.wrapping(error)
                let fallback = self.state.outcome
                self.state = .failed(error: appErr, fallback: fallback)
            }
        }
    }

    private func recordHistory(_ maxUtilization: Double) {
        guard let store = historyStore else { return }
        store.append(maxUtilization: maxUtilization)
        let sample = UsageHistoryStore.Sample(
            at: Date.now.timeIntervalSince1970,
            max: maxUtilization
        )
        let cutoff = Date.now.addingTimeInterval(-24 * 3600).timeIntervalSince1970
        var current = history
        current.append(sample)
        history = current.filter { $0.at >= cutoff }
    }

    public func compactHistory() {
        historyStore?.compact()
    }
}
