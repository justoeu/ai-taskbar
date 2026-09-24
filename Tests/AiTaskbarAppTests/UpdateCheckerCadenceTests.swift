import Foundation
import Testing
import AiTaskbarCore
@testable import AiTaskbarApp

@Suite("UpdateChecker Cadence and Banner Visibility Tests")
struct UpdateCheckerCadenceTests {
    private func makeSuiteDefaults() -> UserDefaults {
        let name = "test-updates-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Cadence interval defaults to 24 hours (86,400 seconds)")
    func cadence_interval_is_24_hours() {
        #expect(UpdateChecker.cadenceInterval == 86_400)
    }

    @Test("checkIfNeeded performs check when never checked before")
    @MainActor
    func check_if_needed_when_never_checked() {
        let defaults = makeSuiteDefaults()
        let config = UpdatesConfig(enabled: true, ownerRepo: "test/repo", includePrereleases: false)
        let checker = UpdateChecker(config: config, currentVersion: "1.0.0", userDefaults: defaults)

        #expect(checker.lastCheckDate == nil)
        #expect(checker.status == .idle)

        checker.checkIfNeeded(force: false)
        #expect(checker.status == .checking)
    }

    @Test("checkIfNeeded skips check when checked within the 24-hour cadence")
    @MainActor
    func check_if_needed_skips_within_cadence() {
        let defaults = makeSuiteDefaults()
        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: UpdateChecker.lastCheckKey)

        let config = UpdatesConfig(enabled: true, ownerRepo: "test/repo", includePrereleases: false)
        let checker = UpdateChecker(config: config, currentVersion: "1.0.0", userDefaults: defaults)

        #expect(checker.lastCheckDate != nil)
        checker.checkIfNeeded(force: false)
        #expect(checker.status == .idle)
    }

    @Test("checkIfNeeded runs when more than 24 hours have elapsed")
    @MainActor
    func check_if_needed_runs_after_cadence_elapsed() {
        let defaults = makeSuiteDefaults()
        let oldTime = Date().addingTimeInterval(-86_401)
        defaults.set(oldTime.timeIntervalSince1970, forKey: UpdateChecker.lastCheckKey)

        let config = UpdatesConfig(enabled: true, ownerRepo: "test/repo", includePrereleases: false)
        let checker = UpdateChecker(config: config, currentVersion: "1.0.0", userDefaults: defaults)

        checker.checkIfNeeded(force: false)
        #expect(checker.status == .checking)
    }

    @Test("checkIfNeeded with force=true bypasses 24-hour cooldown")
    @MainActor
    func check_if_needed_force_bypasses_cooldown() {
        let defaults = makeSuiteDefaults()
        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: UpdateChecker.lastCheckKey)

        let config = UpdatesConfig(enabled: true, ownerRepo: "test/repo", includePrereleases: false)
        let checker = UpdateChecker(config: config, currentVersion: "1.0.0", userDefaults: defaults)

        checker.checkIfNeeded(force: true)
        #expect(checker.status == .checking)
    }

    @Test("Banner visibility reflects available update and handles dismiss correctly")
    @MainActor
    func banner_visibility_and_dismiss() {
        let defaults = makeSuiteDefaults()
        let config = UpdatesConfig(enabled: true, ownerRepo: "test/repo", includePrereleases: false)
        let checker = UpdateChecker(config: config, currentVersion: "1.0.0", userDefaults: defaults)

        #expect(!checker.isUpdateBannerVisible)

        let releaseV11 = UpdateChecker.Release(
            tag: "v1.1.0",
            htmlURL: URL(string: "https://github.com/test/repo/releases/v1.1.0")!,
            prerelease: false,
            publishedAt: Date(),
            dmgURL: URL(string: "https://github.com/test/repo/releases/v1.1.0/app.dmg"),
            dmgSize: 1000,
            dmgSHA256: nil
        )

        checker.setMockStatusForTesting(.updateAvailable(latest: releaseV11))
        #expect(checker.isUpdateBannerVisible)

        // Dismiss current update
        checker.dismissCurrentUpdate()
        #expect(!checker.isUpdateBannerVisible)
        #expect(checker.dismissedTag == "v1.1.0")

        // A newer release appears (v1.2.0) -> banner becomes visible again!
        let releaseV12 = UpdateChecker.Release(
            tag: "v1.2.0",
            htmlURL: URL(string: "https://github.com/test/repo/releases/v1.2.0")!,
            prerelease: false,
            publishedAt: Date(),
            dmgURL: URL(string: "https://github.com/test/repo/releases/v1.2.0/app.dmg"),
            dmgSize: 1000,
            dmgSHA256: nil
        )
        checker.setMockStatusForTesting(.updateAvailable(latest: releaseV12))
        #expect(checker.isUpdateBannerVisible)
    }
}
