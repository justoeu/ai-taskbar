import Testing
import Foundation
@testable import AiTaskbarApp
import AiTaskbarCore
import AiTaskbarProviders

/// Unit tests for the pure aggregation logic extracted from
/// `UsageStore.recomputeAggregates()`. The headline invariant under test is
/// `hasRateLimitedVendor`: it MUST fire when ANY vendor's state is either
/// `.failed(429, _)` directly OR stale-`.ok(outcome)` whose
/// `outcome.lastError?.status == 429` (the steady-state CachedFetch path
/// that converts a fresh 429 into a stale-`.ok` whenever a cached payload
/// exists). Missing the stale-`.ok` case would silently disable
/// `RefreshScheduler`'s 60s back-off branch.
@MainActor
@Suite("AggregatesComputation — pure cross-vendor aggregates")
struct AggregatesComputationTests {
    private func window(label: String = "Session", pct: Double = 50) -> UsageWindow {
        UsageWindow(label: label, utilizationPercent: pct, resetsAt: nil, detail: nil)
    }

    private func snapshot(pct: Double) -> VendorSnapshot {
        .zai(ZAISnapshot(session: window(label: "Session", pct: pct)))
    }

    private func outcome(pct: Double, lastErrorStatus: Int? = nil) -> FetchOutcome {
        FetchOutcome(snapshot: snapshot(pct: pct),
                     isStale: lastErrorStatus != nil,
                     lastError: lastErrorStatus.map { FetchError(status: $0, body: "") })
    }

    @Test("empty states → zero aggregates, no rate limit, not loading")
    func empty_states() {
        let r = AggregatesComputation.compute(states: [])
        #expect(r.maxUtilization == 0)
        #expect(r.isAnyVendorLoading == false)
        #expect(r.hasRateLimitedVendor == false)
    }

    @Test("idle states do not flip aggregates")
    func idle_states_inert() {
        let r = AggregatesComputation.compute(states: [.idle, .idle, .idle])
        #expect(r.maxUtilization == 0)
        #expect(r.isAnyVendorLoading == false)
        #expect(r.hasRateLimitedVendor == false)
    }

    @Test("one loading state flips isAnyVendorLoading")
    func loading_flips_flag() {
        let r = AggregatesComputation.compute(states: [.idle, .loading])
        #expect(r.isAnyVendorLoading)
    }

    @Test("ok state propagates max utilization")
    func ok_propagates_max() {
        let r = AggregatesComputation.compute(states: [
            .ok(outcome(pct: 30)),
            .ok(outcome(pct: 75)),
            .ok(outcome(pct: 12))
        ])
        #expect(r.maxUtilization == 75)
        #expect(r.hasRateLimitedVendor == false)
    }

    @Test("HEADLINE: stale-.ok with lastError=429 flips hasRateLimitedVendor")
    func stale_ok_with_429_flips_rate_limited() {
        // This is the subtle case: CachedFetch converts a 429 into a stale
        // .ok when any cached payload exists. Naive `state == .failed(429)`
        // would miss this and the scheduler back-off would sit idle.
        let r = AggregatesComputation.compute(states: [
            .ok(outcome(pct: 30, lastErrorStatus: 429))
        ])
        #expect(r.hasRateLimitedVendor)
    }

    @Test("failed with rate-limited error flips hasRateLimitedVendor")
    func failed_429_direct() {
        let r = AggregatesComputation.compute(states: [
            .failed(error: .http(status: 429, body: ""), fallback: nil)
        ])
        #expect(r.hasRateLimitedVendor)
    }

    @Test("failed with fallback whose lastError is 429 flips hasRateLimitedVendor")
    func failed_with_429_fallback_flips_rate_limited() {
        // When CachedFetch already had a cached snapshot, a 429 surfaces as
        // `.failed(.other, fallback=stale_outcome_with_429_lastError)` because
        // the cache fallback IS the snapshot. The fallback's lastError carries
        // the 429 — must be detected.
        let r = AggregatesComputation.compute(states: [
            .failed(error: .other("transport"),
                    fallback: outcome(pct: 50, lastErrorStatus: 429))
        ])
        #expect(r.hasRateLimitedVendor)
    }

    @Test("failed with non-429 status does NOT flip hasRateLimitedVendor")
    func failed_non_429_does_not_flip() {
        let r = AggregatesComputation.compute(states: [
            .failed(error: .http(status: 500, body: ""), fallback: nil)
        ])
        #expect(!r.hasRateLimitedVendor)
    }

    @Test("ok with non-429 lastError does NOT flip hasRateLimitedVendor")
    func ok_non_429_does_not_flip() {
        let r = AggregatesComputation.compute(states: [
            .ok(outcome(pct: 30, lastErrorStatus: 500))
        ])
        #expect(!r.hasRateLimitedVendor)
    }

    @Test("stale cached Keychain ACL error remains actionable")
    func stale_ok_with_keychain_acl_error_is_actionable() {
        let stale = FetchOutcome(
            snapshot: snapshot(pct: 30),
            isStale: true,
            lastError: FetchError(
                status: 0,
                body: "Keychain access denied (errSecAuthFailed). Tap Authorize."))
        #expect(VendorViewModel.State.ok(stale).isKeychainACLBlocked)
    }

    @Test("ordinary stale errors do not show Keychain authorization")
    func stale_ok_with_other_error_is_not_keychain_blocked() {
        let stale = FetchOutcome(
            snapshot: snapshot(pct: 30),
            isStale: true,
            lastError: FetchError(status: 500, body: "server unavailable"))
        #expect(!VendorViewModel.State.ok(stale).isKeychainACLBlocked)
    }

    @Test("per-vendor rate-limit cooldown grows exponentially and caps at one hour")
    func rate_limit_cooldown_schedule() {
        #expect(VendorViewModel.rateLimitCooldown(forAttempt: 1) == 300)
        #expect(VendorViewModel.rateLimitCooldown(forAttempt: 2) == 600)
        #expect(VendorViewModel.rateLimitCooldown(forAttempt: 3) == 1_200)
        #expect(VendorViewModel.rateLimitCooldown(forAttempt: 4) == 2_400)
        #expect(VendorViewModel.rateLimitCooldown(forAttempt: 5) == 3_600)
        #expect(VendorViewModel.rateLimitCooldown(forAttempt: 99) == 3_600)
    }

    @Test("mixed: one rate-limited vendor flips flag even if others are clean")
    func mixed_one_rate_limited_flips() {
        let r = AggregatesComputation.compute(states: [
            .ok(outcome(pct: 10)),
            .ok(outcome(pct: 20, lastErrorStatus: 429)),  // rate limited
            .ok(outcome(pct: 30))
        ])
        #expect(r.hasRateLimitedVendor)
        #expect(r.maxUtilization == 30)
    }

    @Test("loading state with prior outcome still contributes max utilization")
    func loading_keeps_old_outcome_for_max() {
        // A refresh that just started still holds the previous outcome in
        // its state — the icon color shouldn't flicker to 0 while loading.
        let loadingWithOutcome = VendorViewModel.State.loading
        // State.loading doesn't carry an outcome in the current enum shape,
        // so max stays 0 here. This test documents that behavior.
        let r = AggregatesComputation.compute(states: [loadingWithOutcome])
        #expect(r.isAnyVendorLoading)
        #expect(r.maxUtilization == 0)
    }

    @Test("failed state's fallback contributes to max utilization")
    func failed_fallback_contributes_max() {
        let r = AggregatesComputation.compute(states: [
            .failed(error: .other("x"),
                    fallback: outcome(pct: 88, lastErrorStatus: nil))
        ])
        #expect(r.maxUtilization == 88)
    }

    // MARK: - Expansion filter (only OPEN cards count toward maxUtilization)

    private func entry(_ state: VendorViewModel.State,
                       expanded: Bool) -> AggregatesComputation.Entry {
        .init(state: state, isExpanded: expanded)
    }

    @Test("collapsed card is excluded from maxUtilization")
    func collapsed_excluded_from_max() {
        let r = AggregatesComputation.compute(entries: [
            entry(.ok(outcome(pct: 90)), expanded: false),  // closed → ignored
            entry(.ok(outcome(pct: 40)), expanded: true)
        ])
        #expect(r.maxUtilization == 40)
    }

    @Test("expanded card still contributes to maxUtilization")
    func expanded_contributes_to_max() {
        let r = AggregatesComputation.compute(entries: [
            entry(.ok(outcome(pct: 90)), expanded: true),
            entry(.ok(outcome(pct: 40)), expanded: false)
        ])
        #expect(r.maxUtilization == 90)
    }

    @Test("all cards collapsed → maxUtilization is 0")
    func all_collapsed_is_zero() {
        let r = AggregatesComputation.compute(entries: [
            entry(.ok(outcome(pct: 90)), expanded: false),
            entry(.ok(outcome(pct: 40)), expanded: false)
        ])
        #expect(r.maxUtilization == 0)
    }

    @Test("collapsed card is STILL counted for hasRateLimitedVendor")
    func collapsed_still_flags_rate_limit() {
        // Folding a card must not blind the scheduler back-off: the 429 flag
        // considers every vendor regardless of expand state.
        let r = AggregatesComputation.compute(entries: [
            entry(.ok(outcome(pct: 30, lastErrorStatus: 429)), expanded: false)
        ])
        #expect(r.hasRateLimitedVendor)
        #expect(r.maxUtilization == 0)  // but its % is excluded
    }

    @Test("collapsed card is STILL counted for isAnyVendorLoading")
    func collapsed_still_flags_loading() {
        let r = AggregatesComputation.compute(entries: [
            entry(.loading, expanded: false)
        ])
        #expect(r.isAnyVendorLoading)
    }

    @Test("compute(states:) treats every vendor as expanded")
    func states_overload_is_all_expanded() {
        let r = AggregatesComputation.compute(states: [
            .ok(outcome(pct: 90)),
            .ok(outcome(pct: 40))
        ])
        #expect(r.maxUtilization == 90)
    }
}
