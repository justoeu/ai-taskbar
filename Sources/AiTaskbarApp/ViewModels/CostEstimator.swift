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

    /// Usage that reached a vendor through opencode rather than that vendor's
    /// own CLI, keyed by the vendor it was billed to.
    ///
    /// Deliberately NOT merged into `byVendor`. opencode is a client, not a
    /// vendor, and the two vendors it feeds need opposite treatment:
    ///
    /// - **OpenAI** rides the ChatGPT subscription, so its marginal cost is
    ///   zero. Pricing those tokens off `PricingTable` would put roughly
    ///   $2.4k/week of notional spend on a card that is supposed to show money
    ///   leaving the account. The tokens are shown; the dollars are not.
    /// - **xAI** is pay-per-token, and its card already reports cycle spend
    ///   from the Management API — which bills the whole account and therefore
    ///   *already contains* this usage. Adding it would double-count. The
    ///   breakdown answers "where did that go", it does not restate the total.
    @Published public private(set) var opencode: [VendorId: OpencodeScan] = [:]

    /// Vendors whose card shows an opencode breakdown, mapped to opencode's
    /// own `providerID` for that vendor.
    /// `nonisolated` because the scan runs on a detached task: the class is
    /// `@MainActor`, so an isolated static would be unreadable from there.
    /// Safe as a `let` of Sendable contents — there is nothing to mutate.
    public nonisolated static let opencodeProviders: [VendorId: String] = [
        .openai: "openai",
        .xai: "xai",
    ]
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
            // One SQLite pass per vendor. Each is ~1s against a 19 GB database
            // because opencode indexes `message` by (session_id, time_created)
            // and there is no index on time alone, so a window query scans.
            // Run alongside the file scanners rather than after them.
            async let opencode = Task {
                Self.opencodeProviders.compactMapValues {
                    OpencodeScanner.scan(provider: $0)
                }
            }
            let claudeEstimate = await claude.value
            let codexEstimate  = await codex.value
            let opencodeScans  = await opencode.value
            // A cancelled scan returns a PARTIAL total (the scanners break out
            // of the file loop). Publishing that would show a number that is
            // silently too low, so drop it and let the next tick recompute.
            guard !Task.isCancelled else { return }
            await MainActor.run { [self] in
                self.byVendor[.anthropic] = claudeEstimate
                self.byVendor[.openai] = codexEstimate
                self.opencode = opencodeScans
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
