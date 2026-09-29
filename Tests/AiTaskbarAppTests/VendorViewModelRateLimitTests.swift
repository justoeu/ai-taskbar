import Testing
import Foundation
import os.lock
@testable import AiTaskbarApp
@testable import AiTaskbarCore
import AiTaskbarProviders

/// Always answers HTTP 429 and counts the calls.
private final class RateLimitedProvider: UsageProvider, @unchecked Sendable {
    let vendorId: VendorId = .openrouter
    var displayName: String { vendorId.displayName }
    var credentialFileURL: URL? { nil }
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    var callCount: Int { calls.withLock { $0 } }
    func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        calls.withLock { $0 += 1 }
        throw AppError.http(status: 429, body: "slow down")
    }
}

/// Answers HTTP 429 only after the test releases it, so the test can move
/// the injected clock while the request is in flight.
private final class GatedRateLimitedProvider: UsageProvider, @unchecked Sendable {
    let vendorId: VendorId = .openrouter
    var displayName: String { vendorId.displayName }
    var credentialFileURL: URL? { nil }
    private let gate = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
    var isWaiting: Bool { gate.withLock { $0 != nil } }
    func release() {
        let c = gate.withLock { c -> CheckedContinuation<Void, Never>? in
            defer { c = nil }
            return c
        }
        c?.resume()
    }
    func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        await withCheckedContinuation { c in gate.withLock { $0 = c } }
        throw AppError.http(status: 429, body: "slow down")
    }
}

/// Test-controlled clock for `VendorViewModel(clock:)`.
@MainActor
private final class ManualClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// CQ-MAE-014: `refresh(forceRefresh:now:)` took an injected clock but only
/// used it for `loadingSince`; the 429 cooldown gate read `Date.now`, so a
/// caller-supplied time past the cooldown was still refused.
@MainActor
@Suite("VendorViewModel rate-limit cooldown clock")
struct VendorViewModelRateLimitTests {
    let tmp: URL
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-vvm-rl-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        suiteName = "ai-taskbar.vvm.rl.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    private func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmp) // test cleanup
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000) // polling; cancellation irrelevant
        }
    }

    private func isFailed(_ vm: VendorViewModel) -> Bool {
        if case .failed = vm.state { return true }
        return false
    }

    @Test("the cooldown gate reads the injected clock, not Date.now")
    func cooldown_uses_injected_now() async throws {
        defer { cleanup() }
        let provider = RateLimitedProvider()
        let dir = tmp
        let vm = VendorViewModel(
            provider: provider, defaults: defaults,
            historyStoreFactory: { UsageHistoryStore(vendor: $0, baseDir: dir) })

        vm.refresh(forceRefresh: true)
        await waitUntil { isFailed(vm) }
        let retryAt = try #require(vm.rateLimitRetryAt)
        #expect(provider.callCount == 1)

        // Inside the cooldown on the injected clock: refused.
        vm.refresh(forceRefresh: true, now: retryAt.addingTimeInterval(-1))
        #expect(provider.callCount == 1)

        // Past the cooldown on the injected clock: allowed.
        vm.refresh(forceRefresh: true, now: retryAt.addingTimeInterval(1))
        await waitUntil { provider.callCount == 2 }
        #expect(provider.callCount == 2)
    }

    /// BUG-MAE-009: the cooldown was stamped from the dispatch time, so a
    /// 429 that took 100 s to arrive got a cooldown 100 s shorter than
    /// `rateLimitCooldown(forAttempt:)`. It must be measured from arrival.
    @Test("a slow 429 is cooled down from its arrival, not its dispatch")
    func cooldown_starts_at_response_arrival() async throws {
        defer { cleanup() }
        let provider = GatedRateLimitedProvider()
        let dir = tmp
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = ManualClock(start)
        let vm = VendorViewModel(
            provider: provider, defaults: defaults,
            historyStoreFactory: { UsageHistoryStore(vendor: $0, baseDir: dir) },
            clock: { clock.now })

        vm.refresh(forceRefresh: true, now: start)
        await waitUntil { provider.isWaiting }
        clock.now = start.addingTimeInterval(100)   // the request is slow
        provider.release()
        await waitUntil { isFailed(vm) }

        let retryAt = try #require(vm.rateLimitRetryAt)
        let expected = start.addingTimeInterval(100 + VendorViewModel.rateLimitCooldown(forAttempt: 1))
        #expect(retryAt == expected)
    }
}
