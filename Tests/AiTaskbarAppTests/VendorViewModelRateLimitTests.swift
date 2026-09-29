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
}
