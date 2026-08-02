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
    /// The opencode scan, tracked separately so it can be cancelled without
    /// touching the scan that owns `isLoading`.
    private var opencodeTask: Task<Void, Never>?
    /// Bumped on every `refresh`. A task only writes state if this still
    /// matches the value it captured — otherwise a scan superseded while a
    /// NEWER one was already running would clear that newer scan's `isLoading`
    /// and null its `inFlight`, stranding it.
    ///
    /// Honest status: this is defensive, NOT test-covered. Reaching the race
    /// needs a cancelled scan to finish while a later one is still in flight,
    /// and with warm memos both complete too fast to force. A test asserting it
    /// was written, passed with the guard deleted, and was removed rather than
    /// kept as false coverage. The guard stays because it is cheap and the
    /// failure it prevents is silent.
    private var generation: UInt64 = 0

    public init() {}

    /// Recomputes scanners if either no result exists or the previous one is
    /// older than `minRecomputeInterval`. `force == true` bypasses the gate.
    public func refresh(force: Bool = false) {
        if isLoading { return }
        if !force, let last = lastComputedAt,
           Date.now.timeIntervalSince(last) < minRecomputeInterval {
            return
        }
        generation &+= 1
        let gen = generation
        isLoading = true
        // Held so a teardown (or a superseding refresh) can cancel the scan.
        // Both scanners poll `Task.isCancelled` between files; without a
        // handle to cancel, that cooperation had nothing to cooperate with.
        inFlight?.cancel()
        // Run scanners as child tasks of this detached task (not nested
        // unstructured Task {}) so cancel() cooperates with Task.isCancelled
        // inside Claude/Codex scanners (BP-HYD-001 / N1-NEX-001).
        inFlight = Task.detached(priority: .utility) {
            async let claude = ClaudeSessionScanner.estimate()
            async let codex = CodexCost.estimate()
            let started = Date()
            let claudeEstimate = await claude
            let codexEstimate = await codex
            // Kept in the shipping build. The cold Claude scan dominates this
            // (5s on the maintainer's machine) and the Models section shows
            // "Loading…" for its whole duration, which is indistinguishable
            // from being stuck. When someone reports it hanging, this line is
            // the difference between measuring and guessing.
            AppLog.cost.info(
                "cost scan finished in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
            // A cancelled scan returns a PARTIAL total (the scanners break out
            // of the file loop). Publishing that would show a number that is
            // silently too low, so drop it and let the next tick recompute.
            //
            // `isLoading` MUST still be cleared on the way out. It gates every
            // future refresh (`if isLoading { return }`), so returning while it
            // is true wedges the Models section on "Loading…" permanently, with
            // no path back — the next refresh bails before it can fix anything.
            guard !Task.isCancelled else {
                await MainActor.run { [self] in
                    guard self.generation == gen else { return }
                    self.isLoading = false
                    self.inFlight = nil
                }
                return
            }
            await MainActor.run { [self] in
                guard self.generation == gen else { return }
                self.byVendor[.anthropic] = claudeEstimate
                self.byVendor[.openai] = codexEstimate
                self.lastComputedAt = .now
                self.isLoading = false
                self.inFlight = nil
            }
        }

        // opencode is scanned on its OWN task rather than inside the one above.
        //
        // It reads a 19 GB SQLite file with no index on time alone, so a window
        // query scans: measured 1.51s for the openai provider and 0.23s for
        // xai. Awaiting that before publishing made the whole Models section
        // wait on it — a cold first open went from ~5s (the Claude scan, which
        // dominates and always has) to ~6.5s, which reads as "it never loads".
        //
        // The two are genuinely independent: nothing in the vendor cost
        // estimate depends on the opencode scan, and the opencode rows render
        // in their own section. Letting each publish when it is ready keeps the
        // slower source from holding the faster one hostage. It also keeps
        // `isLoading` — which drives the spinner and gates refreshes — tied
        // only to the scanners the spinner is actually describing.
        opencodeTask?.cancel()
        opencodeTask = Task.detached(priority: .utility) {
            let scans = Self.opencodeProviders.compactMapValues {
                OpencodeScanner.scan(provider: $0)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [self] in
                guard self.generation == gen else { return }
                self.opencode = scans
                self.opencodeTask = nil
            }
        }
    }

    /// Cancels an in-flight scan. Safe to call when none is running.
    public func cancel() {
        inFlight?.cancel()
        inFlight = nil
        opencodeTask?.cancel()
        opencodeTask = nil
        isLoading = false
    }
}
