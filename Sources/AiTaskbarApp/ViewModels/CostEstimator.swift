import Foundation
import SwiftUI
import AiTaskbarCore

@MainActor
public final class CostEstimator: ObservableObject {
    @Published public private(set) var byVendor: [VendorId: CostEstimate] = [:]
    /// Claude cost per account (`storageKey`) when several are discovered;
    /// `byVendor[.anthropic]` stays their deduped sum.
    @Published public private(set) var byInstance: [String: CostEstimate] = [:]
    @Published public private(set) var lastComputedAt: Date?
    /// Drives the spinner / "Loading…" UI in the Models section. Mirrors
    /// `inFlight` but is `@Published` so views observe transitions.
    @Published public private(set) var isLoading: Bool = false
    /// Vendors with a local scanner; the Models breakdown only makes sense
    /// for these (we have no per-model attribution for OpenRouter / Z.AI /
    /// Kimi balances).
    public static let supportedVendors: Set<VendorId> = [.anthropic, .openai, .meta, .gemini]

    /// Scanner seams keep the refresh state machine independently testable
    /// from the size and contents of the current user's on-disk histories.
    private let claudeEstimate: @Sendable () -> ClaudeSessionScanner.MultiEstimate
    private let codexEstimate: @Sendable () -> CostEstimate
    private let museEstimate: @Sendable () -> CostEstimate
    /// Meta disabled means no scan at all (SDD-meta-muse §4.3): the seam
    /// is not invoked and no `.meta` estimate is published.
    private let museEnabled: Bool
    private let geminiEstimate: @Sendable () -> CostEstimate
    /// Same rule as Meta: Gemini disabled means its local records
    /// (Gemini CLI chats + Antigravity databases) are not scanned.
    private let geminiEnabled: Bool
    private let opencodeScan: @Sendable ([String: [String]]) -> [String: OpencodeScan]?

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

    /// Vendors whose card shows an opencode breakdown, mapped to every
    /// `providerID` alias opencode uses for that billing vendor.
    /// `nonisolated` because the scan runs on a detached task: the class is
    /// `@MainActor`, so an isolated static would be unreadable from there.
    /// Safe as a `let` of Sendable contents — there is nothing to mutate.
    public nonisolated static let opencodeProviders: [VendorId: [String]] = [
        .openai: ["openai"],
        .zai: ["zai", "zai-coding-plan"],
        .xai: ["xai"],
        .gemini: ["gemini", "google"],
    ]
    /// Skip recomputation if the last result is younger than this.
    private let minRecomputeInterval: TimeInterval = 60
    /// The running scan, so it can be cancelled on teardown or supersession.
    private var inFlight: Task<Void, Never>?
    /// The opencode scan, tracked separately so it can be cancelled without
    /// touching the scan that owns `isLoading`.
    private(set) var opencodeTask: Task<Void, Never>?
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

    /// `claudeRoots`: one `projects/` per discovered Claude account; empty
    /// scans `~/.claude/projects` alone, as before multi-account.
    public init(museSessionsDir: URL? = nil, museEnabled: Bool = false,
                geminiEnabled: Bool = false,
                claudeRoots: [ClaudeSessionScanner.Root] = []) {
        self.claudeEstimate = {
            guard !claudeRoots.isEmpty else {
                return ClaudeSessionScanner.MultiEstimate(total: ClaudeSessionScanner.estimate(), byAccount: [:])
            }
            return ClaudeSessionScanner.estimate(roots: claudeRoots)
        }
        self.codexEstimate = { CodexCost.estimate() }
        self.museEstimate = { MuseSessionScanner.estimate(sessionsDir: museSessionsDir) }
        self.museEnabled = museEnabled
        self.geminiEstimate = { GeminiUsageScanner.estimate() }
        self.geminiEnabled = geminiEnabled
        self.opencodeScan = { groups in
            Self.opencodeRows(from: OpencodeScanner.scanOutcome(providerGroups: groups))
        }
    }

    /// A missing database means opencode is not installed: genuinely no rows.
    /// An unavailable scan is a read failure and stays nil, so the previously
    /// published rows are kept (BUG-ART-013). Decided by the scanner's own
    /// probe, not a second `fileExists` that could disagree with it.
    nonisolated static func opencodeRows(from outcome: OpencodeScanner.Outcome)
        -> [String: OpencodeScan]? {
        switch outcome {
        case .notInstalled: return [:]
        case .unavailable: return nil
        case .scanned(let scans): return scans
        }
    }

    /// Test seam. Muse and Gemini default to OFF, as in the public init: on,
    /// their real scanners read this Mac's `~/.local/share/muse` and
    /// `~/.gemini`, so tests that only stubbed Claude/Codex/opencode ran for
    /// seconds and timed out under coverage on a machine with a lot of data.
    internal init(
        claudeEstimate: @escaping @Sendable () -> CostEstimate,
        codexEstimate: @escaping @Sendable () -> CostEstimate,
        opencodeScan: @escaping @Sendable ([String: [String]]) -> [String: OpencodeScan]?,
        museEstimate: @escaping @Sendable () -> CostEstimate = { MuseSessionScanner.estimate() },
        museEnabled: Bool = false,
        geminiEstimate: @escaping @Sendable () -> CostEstimate = { GeminiUsageScanner.estimate() },
        geminiEnabled: Bool = false,
        claudeByAccount: @escaping @Sendable () -> [String: CostEstimate] = { [:] }
    ) {
        self.claudeEstimate = {
            ClaudeSessionScanner.MultiEstimate(total: claudeEstimate(), byAccount: claudeByAccount())
        }
        self.codexEstimate = codexEstimate
        self.opencodeScan = opencodeScan
        self.museEstimate = museEstimate
        self.museEnabled = museEnabled
        self.geminiEstimate = geminiEstimate
        self.geminiEnabled = geminiEnabled
    }

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
        let claudeEstimate = self.claudeEstimate
        let codexEstimate = self.codexEstimate
        let museEstimate = self.museEstimate
        let museEnabled = self.museEnabled
        let geminiEstimate = self.geminiEstimate
        let geminiEnabled = self.geminiEnabled
        let opencodeScan = self.opencodeScan
        // Held so a teardown (or a superseding refresh) can cancel the scan.
        // Both scanners poll `Task.isCancelled` between files; without a
        // handle to cancel, that cooperation had nothing to cooperate with.
        inFlight?.cancel()
        // Run scanners as child tasks of this detached task (not nested
        // unstructured Task {}) so cancel() cooperates with Task.isCancelled
        // inside Claude/Codex scanners (BP-HYD-001 / N1-NEX-001).
        inFlight = Task.detached(priority: .utility) {
            async let claude = claudeEstimate()
            async let codex = codexEstimate()
            async let muse: CostEstimate? = museEnabled ? museEstimate() : nil
            async let gemini: CostEstimate? = geminiEnabled ? geminiEstimate() : nil
            let started = Date()
            let claudeEstimate = await claude
            let codexEstimate = await codex
            let museEstimate = await muse
            let geminiEstimate = await gemini
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
                // One assignment, one emission: two subscript writes on the
                // @Published dictionary fired every subscriber twice per scan
                // (PERF-FLU-001).
                var updated = self.byVendor
                updated[.anthropic] = claudeEstimate.total
                // Set before `byVendor`, which emits on every scan: listeners
                // react to `$byVendor` and read this, so one scan is one
                // recompute.
                self.byInstance = claudeEstimate.byAccount
                updated[.openai] = codexEstimate
                updated[.meta] = museEstimate
                updated[.gemini] = geminiEstimate
                self.byVendor = updated
                self.lastComputedAt = .now
                self.isLoading = false
                self.inFlight = nil
            }
        }

        // opencode is scanned on its OWN task rather than inside the one above.
        //
        // It reads a multi-GB SQLite file with no index on time alone, so the
        // grouped window query needs a full scan. Awaiting that before publishing
        // made the whole Models section
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
            let groups = Dictionary(uniqueKeysWithValues:
                Self.opencodeProviders.map { ($0.key.rawValue, $0.value) })
            // nil = the database exists but could not be read (open, prepare
            // or step failed). That is not "no usage": keep the rows the card
            // shows and let the next refresh retry (BUG-ART-013).
            let rawScans = opencodeScan(groups)
            guard !Task.isCancelled else { return }
            if rawScans == nil {
                AppLog.cost.error("opencode scan failed; keeping the previous rows")
            }
            let scans: [VendorId: OpencodeScan]? = rawScans.map { raw in
                Dictionary(uniqueKeysWithValues: raw.compactMap { key, scan in
                    guard let vendor = VendorId(rawValue: key), !scan.isEmpty else { return nil }
                    return (vendor, scan)
                })
            }
            await MainActor.run { [self] in
                guard self.generation == gen else { return }
                if let scans { self.opencode = scans }
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
