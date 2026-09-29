import Testing
import Foundation
@testable import AiTaskbarApp
import AiTaskbarCore

/// `isLoading` is not just a spinner flag — `refresh()` starts with
/// `if isLoading { return }`, so it is also the gate on every future scan. A
/// path that leaves it true wedges the Models section on "Loading…" forever,
/// and no later refresh can recover because they all bail at that first line.
/// The scanner closures are stubbed here so this state-machine contract does
/// not depend on the size of the developer's real Claude/Codex history.
@Suite("CostEstimator loading state", .serialized)
struct CostEstimatorLoadingTests {

    @MainActor
    private func makeEstimator() -> CostEstimator {
        CostEstimator(
            claudeEstimate: {
                CostEstimate(usdToday: 1, usdLast7Days: 2)
            },
            codexEstimate: {
                CostEstimate(usdToday: 3, usdLast7Days: 4)
            },
            opencodeScan: { _ in [:] }
        )
    }

    @Test("opencode aliases route current Z.AI, xAI and Gemini models to their vendor cards")
    func opencode_aliases_route_to_vendor_cards() {
        expectTrue(CostEstimator.opencodeProviders[.zai] == ["zai", "zai-coding-plan"])
        expectTrue(CostEstimator.opencodeProviders[.xai] == ["xai"])
        expectTrue(CostEstimator.opencodeProviders[.gemini] == ["gemini", "google"])
    }

    /// CQ-MAE-003: "not installed" publishes empty rows; a failed read
    /// publishes nothing so the previous rows stay (BUG-ART-013).
    @Test("opencode outcomes map to empty rows, kept rows, or the scan")
    func opencode_outcome_mapping() {
        let notInstalled = CostEstimator.opencodeRows(from: .notInstalled)
        let unavailable = CostEstimator.opencodeRows(from: .unavailable)
        let scanned = CostEstimator.opencodeRows(from: .scanned(["openai": OpencodeScan()]))
        expectTrue(notInstalled == [:])
        expectTrue(unavailable == nil)
        expectTrue(scanned == ["openai": OpencodeScan()])
    }

    @MainActor
    private func settle(_ e: CostEstimator, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while e.isLoading, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    @Test("a completed refresh clears isLoading and publishes both vendors")
    func refresh_clears_loading() async throws {
        let e = makeEstimator()
        e.refresh()
        expectTrue(e.isLoading)
        try await settle(e)
        expectTrue(!e.isLoading)
        #expect(e.byVendor[.anthropic] != nil)
        #expect(e.byVendor[.openai] != nil)
        #expect(e.lastComputedAt != nil)
    }

    /// Cancelling must leave the estimator refreshable. Before the fix the
    /// cancelled task returned without touching `isLoading`; `cancel()` happens
    /// to clear it, but the task's own exit path did not, so any cancellation
    /// that did not go through `cancel()` left the gate shut permanently.
    @MainActor
    @Test("cancel leaves the estimator able to refresh again")
    func cancel_does_not_wedge() async throws {
        let e = makeEstimator()
        e.refresh()
        e.cancel()
        expectTrue(!e.isLoading)

        // The gate must actually be open: a second refresh has to start and
        // finish. `force` because the first one may have set lastComputedAt.
        e.refresh(force: true)
        try await settle(e)
        expectTrue(!e.isLoading)
        #expect(e.byVendor[.openai] != nil)
    }

    /// BUG-ART-013. `OpencodeScanner` returns nil when the database exists but
    /// cannot be read (open / prepare / step failure, e.g. after a schema
    /// change). That used to become `[:]` and wipe the rows the card was
    /// showing, so a transient read failure looked like "no opencode usage".
    @MainActor
    @Test("a failed opencode scan keeps the previously published rows")
    func failed_opencode_scan_keeps_previous_rows() async throws {
        var usage = OpencodeScan()
        usage.last7DaysByModel["gpt-5.5"] = ModelUsage(inputTokens: 42)
        let first = usage
        let calls = ScanCallCounter()
        let e = CostEstimator(
            claudeEstimate: { CostEstimate(usdToday: 0, usdLast7Days: 0) },
            codexEstimate: { CostEstimate(usdToday: 0, usdLast7Days: 0) },
            opencodeScan: { _ in calls.next() == 1 ? ["openai": first] : nil }
        )
        e.refresh()
        await e.opencodeTask?.value
        try await settle(e)
        #expect(e.opencode[.openai]?.last7DaysByModel["gpt-5.5"]?.inputTokens == 42)

        e.refresh(force: true)
        await e.opencodeTask?.value
        try await settle(e)
        #expect(calls.count == 2)
        #expect(e.opencode[.openai]?.last7DaysByModel["gpt-5.5"]?.inputTokens == 42)
    }

    /// PERF-FLU-001: the two vendor estimates used to be written as two
    /// separate `byVendor[...] =` statements, so every subscriber (Analytics
    /// among them) saw two emissions and recomputed twice per scan.
    @MainActor
    @Test("a completed refresh publishes byVendor exactly once")
    func refresh_publishes_by_vendor_once() async throws {
        let e = makeEstimator()
        var emissions = 0
        let sub = e.$byVendor.dropFirst().sink { _ in emissions += 1 }
        e.refresh(force: true)
        try await settle(e)
        #expect(emissions == 1)
        sub.cancel()
    }

    // REMOVED: two tests that read as coverage and were not. One claimed to
    // guard the generation token, the other opencode's independence; both kept
    // passing with the protection deleted, because the races they describe
    // cannot be forced without a seam to slow a scanner down. Better no test
    // than a green one that guards nothing — see the note on `generation`.
}

/// Thread-safe call counter for the detached opencode scan stub.
private final class ScanCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; return calls }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}
