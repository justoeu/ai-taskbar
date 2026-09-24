import Foundation
import Testing
import AiTaskbarCore
@testable import AiTaskbarApp

@Suite("RefreshScheduler Updates Integration Tests")
struct RefreshSchedulerTests {
    @Test("RefreshScheduler accepts UpdateChecker and triggers check on start")
    @MainActor
    func scheduler_triggers_update_check() async {
        let name = "test-scheduler-updates-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let config = UpdatesConfig(enabled: true, ownerRepo: "test/repo", includePrereleases: false)
        let checker = UpdateChecker(config: config, currentVersion: "1.0.0", userDefaults: defaults)

        let store = UsageStore(vendors: [], primary: .anthropic, refreshIntervalSeconds: 300)
        let scheduler = RefreshScheduler(
            store: store,
            statusStore: nil,
            costEstimator: nil,
            updates: checker,
            interval: 300
        )

        #expect(checker.status == .idle)
        scheduler.start()

        // Give the task a tiny tick on MainActor
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(checker.status == .checking)

        scheduler.stop()
    }
}
