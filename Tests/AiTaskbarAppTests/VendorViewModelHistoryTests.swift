import Testing
import Foundation
import os.lock
@testable import AiTaskbarApp
@testable import AiTaskbarCore
import AiTaskbarProviders

/// Returns one fixed outcome, so a test chooses fresh / cache-hit / stale.
private struct FixedOutcomeProvider: UsageProvider {
    let vendorId: VendorId = .anthropic
    let outcome: FetchOutcome
    var displayName: String { vendorId.displayName }
    var credentialFileURL: URL? { nil }
    func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome { outcome }
}

/// Holds a loader open until the test releases it.
private final class Gate: Sendable {
    private let open = OSAllocatedUnfairLock(initialState: false)
    var isOpen: Bool { open.withLock { $0 } }
    func release() { open.withLock { $0 = true } }
}

private struct FactoryFailure: Error {}

private func outcome(percent: Double, isStale: Bool = false,
                     cacheAge: TimeInterval?) -> FetchOutcome {
    FetchOutcome(
        snapshot: .anthropic(AnthropicSnapshot(
            session: UsageWindow(label: "Session 5h", utilizationPercent: percent))),
        isStale: isStale,
        lastError: isStale ? FetchError(status: 0, body: "offline") : nil,
        cacheAge: cacheAge)
}

@MainActor
@Suite("VendorViewModel history recording")
struct VendorViewModelHistoryTests {
    let tmp: URL
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-vvm-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        suiteName = "ai-taskbar.vvm.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    private func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeVM(_ outcome: FetchOutcome,
                        loader: @escaping VendorViewModel.HistoryLoader = VendorViewModel.detachedHistoryLoad
    ) -> VendorViewModel {
        let dir = tmp
        return VendorViewModel(
            provider: FixedOutcomeProvider(outcome: outcome),
            defaults: defaults,
            historyStoreFactory: { UsageHistoryStore(vendor: $0, baseDir: dir) },
            historyLoader: loader)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func settledOK(_ vm: VendorViewModel) -> Bool {
        if case .ok = vm.state { return true }
        return false
    }

    // MARK: ARCH-ATL-003

    @Test("isExpanded is seeded from the injected defaults")
    func expanded_seeded_from_injected_defaults() {
        defaults.set(false, forKey: VendorViewModel.expansionKey(for: .anthropic))
        let vm = makeVM(outcome(percent: 1, cacheAge: 0))
        #expect(!vm.isExpanded)
        cleanup()
    }

    @Test("toggling isExpanded persists to the injected defaults")
    func expanded_persists_to_injected_defaults() {
        let vm = makeVM(outcome(percent: 1, cacheAge: 0))
        vm.isExpanded = false
        let stored = defaults.object(forKey: VendorViewModel.expansionKey(for: .anthropic)) as? Bool
        expectTrue(stored == false)
        cleanup()
    }

    // MARK: BEST-ATE-006

    @Test("a throwing history-store factory is reported, not silent")
    func throwing_factory_sets_history_unavailable() {
        let vm = VendorViewModel(
            provider: FixedOutcomeProvider(outcome: outcome(percent: 1, cacheAge: 0)),
            defaults: defaults,
            historyStoreFactory: { _ in throw FactoryFailure() })
        #expect(vm.historyUnavailable)
        cleanup()
    }

    @Test("a working history-store factory is not flagged")
    func working_factory_not_flagged() {
        let vm = makeVM(outcome(percent: 1, cacheAge: 0))
        #expect(!vm.historyUnavailable)
        cleanup()
    }

    // MARK: BUG-ART-010

    @Test("a fresh network outcome is recorded once")
    func fresh_outcome_recorded() async {
        let vm = makeVM(outcome(percent: 42, cacheAge: 0))
        vm.refresh(forceRefresh: true)
        await waitUntil { settledOK(vm) }
        let onDisk = vm.historyStore?.load(since: .distantPast).count ?? -1
        #expect(onDisk == 1)
        cleanup()
    }

    @Test("a stale-fallback outcome is not recorded as a new sample")
    func stale_outcome_not_recorded() async {
        let vm = makeVM(outcome(percent: 95, isStale: true, cacheAge: 6 * 3600))
        vm.refresh(forceRefresh: true)
        await waitUntil { settledOK(vm) }
        let onDisk = vm.historyStore?.load(since: .distantPast).count ?? -1
        #expect(onDisk == 0)
        #expect(vm.history.isEmpty)
        cleanup()
    }

    @Test("a cache-hit replay is not recorded as a new sample")
    func cache_hit_not_recorded() async {
        let vm = makeVM(outcome(percent: 30, cacheAge: 120))
        vm.refresh(forceRefresh: false)
        await waitUntil { settledOK(vm) }
        let onDisk = vm.historyStore?.load(since: .distantPast).count ?? -1
        #expect(onDisk == 0)
        #expect(vm.history.isEmpty)
        cleanup()
    }

    // MARK: RACE-CRO-011

    @Test("the initial history load does not drop a sample recorded meanwhile")
    func initial_load_merges_with_recorded_sample() async {
        let gate = Gate()
        let old = UsageHistoryStore.Sample(at: Date.now.addingTimeInterval(-3600).timeIntervalSince1970,
                                           max: 10)
        let vm = makeVM(outcome(percent: 42, cacheAge: 0)) { _, _ in
            while !gate.isOpen { try? await Task.sleep(nanoseconds: 2_000_000) }
            return [old]
        }
        vm.refresh(forceRefresh: true)
        await waitUntil { vm.history.count == 1 }
        gate.release()
        await waitUntil { vm.history.contains(old) }
        #expect(vm.history.count == 2)
        #expect(vm.history.last?.max == 42)
        #expect(vm.history.first == old)
        cleanup()
    }
}
