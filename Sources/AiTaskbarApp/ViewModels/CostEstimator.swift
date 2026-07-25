import Foundation
import SwiftUI
import AiTaskbarCore

@MainActor
public final class CostEstimator: ObservableObject {
    @Published public private(set) var byVendor: [VendorId: CostEstimate] = [:]
    @Published public private(set) var lastComputedAt: Date?
    /// Drives the spinner / "Loading…" UI in the Models section. Mirrors
    /// `inFlight` but is `@Published` so views observe transitions.
    @Published public private(set) var isLoading: Bool = false
    /// Vendors with a local scanner; the Models breakdown only makes sense
    /// for these (we have no per-model attribution for OpenRouter / Z.AI /
    /// Kimi balances).
    public static let supportedVendors: Set<VendorId> = [.anthropic, .openai]
    /// Skip recomputation if the last result is younger than this.
    private let minRecomputeInterval: TimeInterval = 60
    /// The running scan, so it can be cancelled on teardown or supersession.
    private var inFlight: Task<Void, Never>?

    public init() {}

    /// Recomputes scanners if either no result exists or the previous one is
    /// older than `minRecomputeInterval`. `force == true` bypasses the gate.
    public func refresh(force: Bool = false) {
        if isLoading { return }
        if !force, let last = lastComputedAt,
           Date.now.timeIntervalSince(last) < minRecomputeInterval {
            return
        }
        isLoading = true
        // Held so a teardown (or a superseding refresh) can cancel the scan.
        // Both scanners poll `Task.isCancelled` between files; without a
        // handle to cancel, that cooperation had nothing to cooperate with.
        inFlight?.cancel()
        inFlight = Task.detached(priority: .utility) {
            async let claude = Task { ClaudeSessionScanner.estimate() }
            async let codex  = Task { CodexCost.estimate() }
            let claudeEstimate = await claude.value
            let codexEstimate  = await codex.value
            // A cancelled scan returns a PARTIAL total (the scanners break out
            // of the file loop). Publishing that would show a number that is
            // silently too low, so drop it and let the next tick recompute.
            guard !Task.isCancelled else { return }
            await MainActor.run { [self] in
                self.byVendor[.anthropic] = claudeEstimate
                self.byVendor[.openai] = codexEstimate
                self.lastComputedAt = .now
                self.isLoading = false
                self.inFlight = nil
            }
        }
    }

    /// Cancels an in-flight scan. Safe to call when none is running.
    public func cancel() {
        inFlight?.cancel()
        inFlight = nil
        isLoading = false
    }
}
