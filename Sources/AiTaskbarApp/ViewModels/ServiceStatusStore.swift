import Foundation
import SwiftUI
import AiTaskbarCore
import AiTaskbarProviders

/// Main-actor state for the public service-status surface. Status refreshes
/// deliberately have no dependency on usage credentials, errors, or 429
/// back-off: the only shared input is the ordered set of enabled vendor IDs.
@MainActor
public final class ServiceStatusStore: ObservableObject {
    public struct Row: Identifiable, Equatable {
        public enum State: Equatable {
            case idle
            case loading(previous: ServiceStatusOutcome?)
            case ok(ServiceStatusOutcome)
            case failed(error: AppError, fallback: ServiceStatusOutcome?)
            case unavailable(VendorServiceStatus)

            public var outcome: ServiceStatusOutcome? {
                switch self {
                case .loading(let previous): return previous
                case .ok(let outcome): return outcome
                case .failed(_, let fallback): return fallback
                case .idle, .unavailable: return nil
                }
            }

            public var status: VendorServiceStatus? {
                switch self {
                case .unavailable(let status): return status
                default: return outcome?.snapshot
                }
            }

            public var isStale: Bool {
                switch self {
                case .ok(let outcome): return outcome.isStale
                case .failed(_, let fallback): return fallback != nil
                default: return false
                }
            }

            public var error: AppError? {
                if case .failed(let error, _) = self { return error }
                return nil
            }
        }

        public let vendorId: VendorId
        public let state: State
        public var id: VendorId { vendorId }

        public init(vendorId: VendorId, state: State) {
            self.vendorId = vendorId
            self.state = state
        }
    }

    @Published public private(set) var rows: [Row]
    @Published public private(set) var overallLevel: ServiceStatusLevel = .unknown
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastCompletedRefreshAt: Date?

    private let providersById: [VendorId: any ServiceStatusProvider]
    public var hasAutomaticSources: Bool { !providersById.isEmpty }
    private var epoch = 0
    private var refreshTask: Task<Void, Never>?

    public init(
        vendorIds: [VendorId],
        providers: [any ServiceStatusProvider]
    ) {
        var seen = Set<VendorId>()
        let orderedIds = vendorIds.filter { seen.insert($0).inserted }
        let eligibleIds = Set(orderedIds.filter {
            ServiceStatusPresentation.expectedCoverage(for: $0) != .linkOnly
        })
        var providerMap: [VendorId: any ServiceStatusProvider] = [:]
        for provider in providers
        where eligibleIds.contains(provider.vendorId) && providerMap[provider.vendorId] == nil {
            providerMap[provider.vendorId] = provider
        }
        providersById = providerMap
        rows = orderedIds.map { vendorId in
            let coverage = ServiceStatusPresentation.expectedCoverage(for: vendorId)
            if coverage == .linkOnly {
                return Row(
                    vendorId: vendorId,
                    state: .unavailable(Self.placeholder(for: vendorId, coverage: .linkOnly))
                )
            }
            if providerMap[vendorId] == nil {
                return Row(
                    vendorId: vendorId,
                    state: .failed(
                        error: .disabled("Automatic service-status source unavailable"),
                        fallback: nil
                    )
                )
            }
            return Row(vendorId: vendorId, state: .idle)
        }
        recomputeAggregates()
    }

    /// Starts a coherent parallel round. A newer call cancels the old task,
    /// bumps the epoch, and keeps the prior outcomes visible while loading.
    public func refreshAll(
        forceRefresh: Bool = false,
        now: Date = .now
    ) {
        epoch += 1
        let roundEpoch = epoch
        refreshTask?.cancel()

        let previous = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.vendorId, $0.state.outcome)
        })
        let requests = rows.compactMap { row -> (VendorId, any ServiceStatusProvider)? in
            guard let provider = providersById[row.vendorId] else { return nil }
            return (row.vendorId, provider)
        }

        guard !requests.isEmpty else {
            refreshTask = nil
            recomputeAggregates()
            return
        }

        rows = rows.map { row in
            guard providersById[row.vendorId] != nil else { return row }
            return Row(vendorId: row.vendorId,
                       state: .loading(previous: previous[row.vendorId] ?? nil))
        }
        recomputeAggregates()

        refreshTask = Task { [weak self] in
            let results = await withTaskGroup(
                of: StatusFetchResult.self,
                returning: [StatusFetchResult].self
            ) { group in
                for (vendorId, provider) in requests {
                    group.addTask {
                        do {
                            let outcome = try await provider.fetchStatus(
                                forceRefresh: forceRefresh,
                                now: now
                            )
                            try Task.checkCancellation()
                            return .success(vendorId, outcome)
                        } catch is CancellationError {
                            return .cancelled(vendorId)
                        } catch {
                            return .failure(vendorId, AppError.wrapping(error))
                        }
                    }
                }
                var collected: [StatusFetchResult] = []
                for await result in group { collected.append(result) }
                return collected
            }

            guard let self, !Task.isCancelled, roundEpoch == self.epoch else { return }
            let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.vendorId, $0) })
            self.rows = self.rows.map { row in
                guard let result = byId[row.vendorId] else { return row }
                switch result {
                case .success(_, let outcome):
                    return Row(vendorId: row.vendorId, state: .ok(outcome))
                case .failure(_, let error):
                    return Row(
                        vendorId: row.vendorId,
                        state: .failed(
                            error: error,
                            fallback: previous[row.vendorId] ?? nil
                        )
                    )
                case .cancelled:
                    if let outcome = previous[row.vendorId] ?? nil {
                        return Row(vendorId: row.vendorId, state: .ok(outcome))
                    }
                    return Row(vendorId: row.vendorId, state: .idle)
                }
            }
            self.lastCompletedRefreshAt = .now
            self.recomputeAggregates()
        }
    }

    /// Awaitable seam used by deterministic tests and callers that need to
    /// observe a complete round. The UI normally observes published state.
    public func waitForCurrentRefresh() async {
        let task = refreshTask
        await task?.value
    }

    private func recomputeAggregates() {
        let levels = rows.map { row -> ServiceStatusLevel in
            guard let status = row.state.status else { return .unknown }
            if status.coverage != .full && status.level == .operational {
                return .unknown
            }
            return status.level
        }
        let nextLevel = ServiceStatusWindow.worstLevel(in: levels)
        let nextLoading = rows.contains { row in
            if case .loading = row.state { return true }
            return false
        }
        if overallLevel != nextLevel { overallLevel = nextLevel }
        if isLoading != nextLoading { isLoading = nextLoading }
    }

    private static func placeholder(
        for vendorId: VendorId,
        coverage: ServiceStatusCoverage
    ) -> VendorServiceStatus {
        VendorServiceStatus(
            vendorId: vendorId,
            level: .unknown,
            coverage: coverage,
            summary: "",
            sourceURL: vendorId.statusPageURL,
            sourceUpdatedAt: nil,
            incidents: []
        )
    }
}

private enum StatusFetchResult: Sendable {
    case success(VendorId, ServiceStatusOutcome)
    case failure(VendorId, AppError)
    case cancelled(VendorId)

    var vendorId: VendorId {
        switch self {
        case .success(let vendorId, _),
             .failure(let vendorId, _),
             .cancelled(let vendorId):
            return vendorId
        }
    }
}
