import Foundation
import Testing
import AiTaskbarCore
@testable import AiTaskbarApp

/// Fails every request at once, so a check started here never reaches the
/// real network. Immutable, safe without `.serialized`.
private final class OfflineDueProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// UPDATE-SCHED-001: a check is due with no previous check, on a new LOCAL
/// calendar day, or after 24 h; otherwise it waits for whichever comes first.
/// Every case runs in a fixed calendar and time zone so it is deterministic.
@Suite("UpdateChecker daily cadence (UPDATE-SCHED-001)")
struct UpdateCheckDueTests {
    static let saoPaulo: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }()

    static func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func isDue(_ last: Date?, _ now: Date) -> Bool {
        UpdateChecker.isCheckDue(lastCheck: last, now: now, calendar: Self.saoPaulo)
    }

    private func delay(_ last: Date?, _ now: Date) -> TimeInterval {
        UpdateChecker.delayUntilNextCheck(lastCheck: last, now: now, calendar: Self.saoPaulo)
    }

    @Test("never checked: due now, no delay")
    func never_checked_is_due() {
        let now = Self.at("2026-09-29T10:00:00-03:00")
        #expect(isDue(nil, now))
        #expect(delay(nil, now) == 0)
    }

    @Test("checked 10 h ago today: not due, waits until the next local midnight")
    func same_day_waits_for_midnight() {
        let last = Self.at("2026-09-29T08:00:00-03:00")
        let now = Self.at("2026-09-29T18:00:00-03:00")
        #expect(!isDue(last, now))
        #expect(delay(last, now) == 6 * 3_600)
    }

    @Test("checked 23:34 yesterday, reopened 10:00: due immediately")
    func previous_day_is_due() {
        let last = Self.at("2026-09-28T23:34:00-03:00")
        let now = Self.at("2026-09-29T10:00:00-03:00")
        #expect(isDue(last, now))
        #expect(delay(last, now) == 0)
    }

    @Test("checked 25 h ago: due")
    func older_than_a_day_is_due() {
        let now = Self.at("2026-09-29T10:00:00-03:00")
        let last = now.addingTimeInterval(-25 * 3_600)
        #expect(isDue(last, now))
    }

    @Test("last check in the future (clock skew): not due, delay capped at 24 h")
    func future_last_check_is_capped() {
        let now = Self.at("2026-09-29T10:00:00-03:00")
        let last = now.addingTimeInterval(2 * 86_400)
        #expect(!isDue(last, now))
        #expect(delay(last, now) == UpdateChecker.cadenceInterval)
    }

    @Test("seconds before midnight: delay floored so a busy check cannot spin")
    func delay_has_a_floor() {
        let last = Self.at("2026-09-29T23:59:30-03:00")
        let now = Self.at("2026-09-29T23:59:50-03:00")
        #expect(!isDue(last, now))
        #expect(delay(last, now) == UpdateChecker.minimumRetryDelay)
    }

    // 2018-11-04 00:00 BRT: clocks jumped to 01:00, so that day starts at 01:00.
    @Test("DST start (Sao Paulo 2018-11-04): waits for the 01:00 start of day")
    func dst_start_waits_for_shifted_day_start() {
        let last = Self.at("2018-11-03T22:00:00-03:00")
        let now = Self.at("2018-11-03T23:00:00-03:00")
        #expect(!isDue(last, now))
        #expect(delay(last, now) == 3_600)
    }

    @Test("DST start (Sao Paulo 2018-11-04): the new day is due 2 h after the last check")
    func dst_start_new_day_is_due() {
        let last = Self.at("2018-11-03T22:00:00-03:00")
        let now = Self.at("2018-11-04T01:00:00-02:00")
        #expect(isDue(last, now))
    }

    // 2019-02-17 00:00 BRST: clocks fell back to 2019-02-16 23:00 (a 25-h day).
    @Test("DST end (Sao Paulo 2019-02-16, 25 h day): the 24 h bound wins over midnight")
    func dst_end_uses_24h_bound() {
        let last = Self.at("2019-02-16T00:30:00-02:00")
        let now = last.addingTimeInterval(3_600)
        #expect(!isDue(last, now))
        #expect(delay(last, now) == 23 * 3_600)
    }

    @Test("DST end (Sao Paulo 2019-02-16): 24 h later on the same local day is due")
    func dst_end_same_day_after_24h_is_due() {
        let last = Self.at("2019-02-16T00:30:00-02:00")
        let now = last.addingTimeInterval(86_400)
        let sameDay = Self.saoPaulo.isDate(last, inSameDayAs: now)
        #expect(sameDay)
        #expect(isDue(last, now))
    }

    @Test("checkIfNeeded checks on a relaunch the next local day and records that time")
    @MainActor
    func check_if_needed_runs_on_new_day() {
        let name = "test-update-due-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Self.at("2026-09-28T23:34:00-03:00").timeIntervalSince1970,
                     forKey: UpdateChecker.lastCheckKey)
        let now = Self.at("2026-09-29T10:00:00-03:00")
        let checker = UpdateChecker(
            config: UpdatesConfig(enabled: true, ownerRepo: "test/repo", includePrereleases: false),
            currentVersion: "1.0.0",
            http: .stubbed(protocols: [OfflineDueProtocol.self]),
            userDefaults: defaults,
            calendar: Self.saoPaulo,
            now: { now })

        checker.checkIfNeeded()
        #expect(checker.status == .checking)
        expectTrue(checker.lastCheckDate == now)
    }

    // MARK: launch rule

    @Test("every launch checks unless the last check was under 5 minutes ago")
    func launch_check_due() {
        let now = Self.at("2026-09-29T10:00:00-03:00")
        #expect(UpdateChecker.isLaunchCheckDue(lastCheck: nil, now: now))
        #expect(UpdateChecker.isLaunchCheckDue(lastCheck: now.addingTimeInterval(-2 * 3_600), now: now))
        #expect(UpdateChecker.isLaunchCheckDue(lastCheck: now.addingTimeInterval(-UpdateChecker.launchMinimumInterval), now: now))
        #expect(!UpdateChecker.isLaunchCheckDue(lastCheck: now.addingTimeInterval(-60), now: now))
        #expect(!UpdateChecker.isLaunchCheckDue(lastCheck: now, now: now))
        // A future last check (clock skew) re-syncs at launch.
        #expect(UpdateChecker.isLaunchCheckDue(lastCheck: now.addingTimeInterval(3_600), now: now))
        #expect(UpdateChecker.launchMinimumInterval == 300)
    }
}
