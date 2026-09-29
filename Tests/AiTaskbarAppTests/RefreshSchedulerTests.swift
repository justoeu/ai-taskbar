import Foundation
import Testing
import AiTaskbarCore
import AiTaskbarProviders
@testable import AiTaskbarApp

// MARK: - Test doubles

/// Accepts every request and never answers it, so an update check stays in
/// `.checking` for as long as the test needs and nothing reaches the network.
/// Stateless; the suite is `.serialized` by the URLProtocol convention.
private final class HangingGitHubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private func okOutcome() -> FetchOutcome {
    FetchOutcome(snapshot: .zai(ZAISnapshot(
        session: UsageWindow(label: "Session", utilizationPercent: 10))))
}

/// Answers immediately and counts how often the scheduler asked.
private struct CountingProvider: UsageProvider {
    let vendorId: VendorId
    let calls = CallCounter()
    var displayName: String { vendorId.displayName }
    var credentialFileURL: URL? { nil }
    func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        calls.increment()
        return okOutcome()
    }
}

/// Always fails with HTTP 429.
private struct RateLimitedProvider: UsageProvider {
    let vendorId: VendorId = .zai
    var displayName: String { vendorId.displayName }
    var credentialFileURL: URL? { nil }
    func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        throw AppError.http(status: 429, body: "")
    }
}

/// A fetch that never completes on its own (the hung-Antigravity shape).
/// `release()` lets the test clean up the parked task afterwards.
private final class HangingProvider: UsageProvider, @unchecked Sendable {
    let vendorId: VendorId = .anthropic
    let calls = CallCounter()
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    var displayName: String { vendorId.displayName }
    var credentialFileURL: URL? { nil }
    func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        calls.increment()
        for await _ in stream {}
        throw CancellationError()
    }
    func release() { continuation.finish() }
}

/// A fetch that parks until its task is cancelled (a superseding refresh
/// cancels it). Counts calls and cancellations. Unlike `HangingProvider` it
/// tolerates overlapping calls, which a restart produces.
private final class ParkingProvider: UsageProvider, @unchecked Sendable {
    let vendorId: VendorId = .anthropic
    let calls = CallCounter()
    let cancellations = CallCounter()
    var displayName: String { vendorId.displayName }
    var credentialFileURL: URL? { nil }
    func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        calls.increment()
        do {
            try await Task.sleep(for: .seconds(3_600))   // ends on cancellation
        } catch {
            cancellations.increment()
            throw error
        }
        throw CancellationError()
    }
}

private struct NoHistory: Error {}

/// Stands in for `Task.sleep` in the refresh loop. Before each sleep it waits
/// for `ready` (the previous tick's fetches have settled), records the
/// requested duration and whether the store was in 429 back-off, and then
/// returns at once — except after `returningSleeps` sleeps, where it parks
/// until `stop()`/deinit cancels the loop.
@MainActor
private final class ScriptedSleeper {
    private(set) var durations: [TimeInterval] = []
    /// Fake time: the sum of every requested sleep. Feed it to the
    /// scheduler's clock so a tick "happens" `interval` after the previous one.
    private(set) var elapsed: TimeInterval = 0
    private(set) var backoffFlags: [Bool] = []
    weak var store: UsageStore?
    private let returningSleeps: Int
    private let ready: @MainActor () -> Bool
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(returningSleeps: Int, ready: @escaping @MainActor () -> Bool = { true }) {
        self.returningSleeps = returningSleeps
        self.ready = ready
    }

    var sleeper: RefreshScheduler.Sleeper { { [self] seconds in await self.sleep(seconds) } }

    private func sleep(_ seconds: TimeInterval) async {
        // Condition wait, not a timing window: bounded only so a broken
        // precondition fails the test instead of hanging it.
        var spins = 0
        while !ready(), spins < 5_000 {
            try? await Task.sleep(for: .milliseconds(1))
            spins += 1
        }
        durations.append(seconds)
        elapsed += seconds
        backoffFlags.append(store?.isInRateLimitBackoff ?? false)
        let count = durations.count
        waiters.removeAll { waiter in
            guard count >= waiter.count else { return false }
            waiter.continuation.resume()
            return true
        }
        if count > returningSleeps {
            try? await Task.sleep(for: .seconds(3_600)) // ends on cancellation
        }
    }

    func waitForSleeps(_ count: Int) async {
        if durations.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

// MARK: - Suite

@Suite("RefreshScheduler", .serialized, .timeLimit(.minutes(1)))
@MainActor
final class RefreshSchedulerTests {
    private let suiteName = "test-refresh-scheduler-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func vendor(_ provider: any UsageProvider) -> VendorViewModel {
        VendorViewModel(provider: provider, defaults: defaults,
                        historyStoreFactory: { _ in throw NoHistory() })
    }

    private func store(_ vendors: [VendorViewModel]) -> UsageStore {
        UsageStore(vendors: vendors, primary: nil, preferredOrder: [])
    }

    private func scheduler(_ store: UsageStore, sleeper: ScriptedSleeper,
                           updates: UpdateChecker? = nil) -> RefreshScheduler {
        sleeper.store = store
        return RefreshScheduler(store: store, statusStore: nil, updates: updates,
                                interval: 300, minimumInterval: 15,
                                minimumStatusInterval: 300, sleeper: sleeper.sleeper)
    }

    private static func isLoading(_ vm: VendorViewModel) -> Bool {
        vm.state.isLoading
    }

    @Test("start() triggers an update check through the injected, non-network client")
    func scheduler_triggers_update_check() async {
        let checker = UpdateChecker(
            config: UpdatesConfig(enabled: true, ownerRepo: "test/repo", includePrereleases: false),
            currentVersion: "1.0.0",
            http: .stubbed(protocols: [HangingGitHubProtocol.self]),
            userDefaults: defaults)
        let sleeper = ScriptedSleeper(returningSleeps: 0)
        let usage = store([])
        let scheduler = scheduler(usage, sleeper: sleeper, updates: checker)

        #expect(checker.status == .idle)
        scheduler.start()
        // Await the transition itself instead of sleeping a fixed window. The
        // stub never answers, so `.checking` is the steady state afterwards.
        for await status in checker.$status.values where status == .checking { break }
        #expect(checker.status == .checking)
        scheduler.stop()
    }

    @Test("a 429 adds rateLimitBackoff to the interval, entering and leaving back-off around it")
    func rateLimited_cycle_backs_off() async {
        let usage = store([vendor(RateLimitedProvider())])
        let sleeper = ScriptedSleeper(returningSleeps: 2, ready: { [weak usage] in
            usage?.hasRateLimitedVendor ?? false
        })
        let scheduler = scheduler(usage, sleeper: sleeper)
        scheduler.start()
        await sleeper.waitForSleeps(3)
        scheduler.stop()

        #expect(sleeper.durations == [300, RefreshScheduler.rateLimitBackoff, 300])
        #expect(RefreshScheduler.rateLimitBackoff == 60)
        #expect(sleeper.backoffFlags == [false, true, false])
        #expect(!usage.isInRateLimitBackoff)
    }

    @Test("a healthy cycle sleeps only the interval")
    func healthy_cycle_has_no_backoff() async {
        let provider = CountingProvider(vendorId: .zai)
        let vm = vendor(provider)
        let sleeper = ScriptedSleeper(returningSleeps: 2, ready: { [weak vm] in
            vm.map { !Self.isLoading($0) } ?? true
        })
        let usage = store([vm])   // the scheduler holds its store weakly
        let scheduler = scheduler(usage, sleeper: sleeper)
        scheduler.start()
        await sleeper.waitForSleeps(3)
        scheduler.stop()

        #expect(sleeper.durations == [300, 300, 300])
        #expect(provider.calls.count == 3)
    }

    @Test("a vendor whose fetch never finishes does not stop the others from refreshing (RACE-CRO-003)")
    func hung_vendor_does_not_starve_others() async {
        let hung = HangingProvider()
        let healthy = CountingProvider(vendorId: .zai)
        let healthyVM = vendor(healthy)
        let usage = store([vendor(hung), healthyVM])   // held: the scheduler's ref is weak
        // Ready once the healthy fetch settled AND the throttled aggregate has
        // caught up with the hung vendor (in production ticks are 300 s apart,
        // far beyond the 50 ms throttle).
        let sleeper = ScriptedSleeper(returningSleeps: 3, ready: { [weak healthyVM, weak usage] in
            guard let healthyVM, let usage else { return true }
            return !Self.isLoading(healthyVM) && usage.isAnyVendorLoading
        })
        let scheduler = scheduler(usage, sleeper: sleeper)
        scheduler.start()
        // Initial tick + one tick after each of the three returning sleeps;
        // the 4th sleep waits for the 3rd tick's fetch to settle.
        await sleeper.waitForSleeps(4)
        scheduler.stop()
        hung.release()

        #expect(healthy.calls.count == 4)
        // Single-flight per vendor: the hung fetch is never stacked/superseded.
        #expect(hung.calls.count == 1)
    }

    /// RACE-MAE-001: a fetch that never returns used to keep its vendor out
    /// of every later scheduled tick until a manual refresh.
    @Test("a fetch in flight for maxInFlightAge is superseded by the next tick")
    func hung_vendor_is_restarted_after_max_age() async throws {
        let parked = ParkingProvider()
        let vm = vendor(parked)
        let usage = store([vm])
        let sleeper = ScriptedSleeper(returningSleeps: 3)
        sleeper.store = usage
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = RefreshScheduler(
            store: usage, statusStore: nil, interval: 300,
            minimumInterval: 15, minimumStatusInterval: 300,
            sleeper: sleeper.sleeper,
            clock: { [sleeper] in base.addingTimeInterval(sleeper.elapsed) })
        scheduler.start()
        // Ticks at t = 0, 300, 600, 900. The fetch started at 0 is 600 s old
        // at the third tick, so that tick restarts it; at 900 the new fetch
        // is 300 s old and is left alone.
        await sleeper.waitForSleeps(4)
        scheduler.stop()
        // Condition wait for the restarted fetch task to start, bounded so a
        // missing restart fails instead of hanging.
        for _ in 0..<2_000 where parked.calls.count < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(parked.calls.count == 2)
    }

    @Test("a fetch younger than maxInFlightAge is not superseded")
    func young_in_flight_fetch_is_skipped() {
        let parked = ParkingProvider()
        let vm = vendor(parked)
        let usage = store([vm])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        usage.refreshIdleVendors(now: start)
        usage.refreshIdleVendors(now: start.addingTimeInterval(UsageStore.maxInFlightAge - 1))
        #expect(vm.loadingSince == start)
    }

    @Test("a fetch at maxInFlightAge is superseded with a new start time")
    func old_in_flight_fetch_is_restarted() {
        let parked = ParkingProvider()
        let vm = vendor(parked)
        let usage = store([vm])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let later = start.addingTimeInterval(UsageStore.maxInFlightAge)
        usage.refreshIdleVendors(now: start)
        usage.refreshIdleVendors(now: later)
        #expect(vm.loadingSince == later)
    }

    @Test("dropping the last reference releases a started scheduler (LEAK-FAN-008)")
    func started_scheduler_is_released() async {
        let checker = UpdateChecker(
            config: UpdatesConfig(enabled: true, ownerRepo: "test/repo", includePrereleases: false),
            currentVersion: "1.0.0",
            http: .stubbed(protocols: [HangingGitHubProtocol.self]),
            userDefaults: defaults)
        let usage = store([])
        let status = ServiceStatusStore(vendorIds: [], providers: [])
        let sleeper = ScriptedSleeper(returningSleeps: 0)
        sleeper.store = usage
        var scheduler: RefreshScheduler? = RefreshScheduler(
            store: usage, statusStore: status, updates: checker,
            interval: 300, minimumInterval: 15, minimumStatusInterval: 300,
            sleeper: sleeper.sleeper)
        weak let released = scheduler
        scheduler?.start()
        // All three self-capturing loops reach their first sleep.
        await sleeper.waitForSleeps(1)
        for await state in checker.$status.values where state == .checking { break }
        // No status rows → no fetch task: that loop goes straight from its
        // first (synchronous) round to its sleep once it has run at all.
        await status.waitForCurrentRefresh()
        await Task.yield()
        scheduler = nil

        expectTrue(released == nil)
        released?.stop()                          // cleanup when the assertion fails
    }
}
