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
        Task.detached(priority: .utility) {
            async let claude = Task { ClaudeSessionScanner.estimate() }
            async let codex  = Task { CodexLogScanner.estimate() }
            let claudeEstimate = await claude.value
            let codexEstimate  = await codex.value
            await MainActor.run { [self] in
                self.byVendor[.anthropic] = claudeEstimate
                self.byVendor[.openai] = codexEstimate
                self.lastComputedAt = .now
                self.isLoading = false
            }
        }
    }
}
