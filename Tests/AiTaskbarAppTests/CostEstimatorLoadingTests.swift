import Testing
import Foundation
@testable import AiTaskbarApp
import AiTaskbarTestSupport

/// `isLoading` is not just a spinner flag — `refresh()` starts with
/// `if isLoading { return }`, so it is also the gate on every future scan. A
/// path that leaves it true wedges the Models section on "Loading…" forever,
/// and no later refresh can recover because they all bail at that first line.
/// `.serialized` is load-bearing: each test drives a real `CostEstimator`,
/// which scans ~/.claude and a 19 GB SQLite file. Four of those racing each
/// other starve the scans past any sane timeout — the suite failed exactly
/// that way before, and in isolation every test passed.
@Suite("CostEstimator loading state", .serialized)
struct CostEstimatorLoadingTests {

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
        let e = CostEstimator()
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
        let e = CostEstimator()
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

    // REMOVED: two tests that read as coverage and were not. One claimed to
    // guard the generation token, the other opencode's independence; both kept
    // passing with the protection deleted, because the races they describe
    // cannot be forced without a seam to slow a scanner down. Better no test
    // than a green one that guards nothing — see the note on `generation`.
}
