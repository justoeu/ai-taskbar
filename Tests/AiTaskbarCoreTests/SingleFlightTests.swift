import Testing
import Foundation
@testable import AiTaskbarCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

@Suite("SingleFlight")
struct SingleFlightTests {
    @Test("concurrent callers share one operation and its result")
    func concurrent_callers_share_one_run() async throws {
        let flight = SingleFlight<Int>()
        let runs = Counter()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await flight.run {
                        let n = runs.next()
                        try await Task.sleep(nanoseconds: 100_000_000)
                        return n
                    }
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(runs.count == 1)
        #expect(Set(results) == [1])
    }

    @Test("a finished flight clears the slot, so the next call runs again")
    func finished_flight_allows_next_run() async throws {
        let flight = SingleFlight<Int>()
        let runs = Counter()
        let first = try await flight.run { runs.next() }
        let second = try await flight.run { runs.next() }
        #expect(first == 1)
        #expect(second == 2)
    }

    @Test("an error reaches every joined caller and clears the slot")
    func error_propagates_and_clears() async throws {
        let flight = SingleFlight<Int>()
        await #expect(throws: AppError.self) {
            try await flight.run { throw AppError.credentials("boom") }
        }
        let after = try await flight.run { 7 }
        #expect(after == 7)
    }

    /// RACE-MAE-002, decided behaviour: a flight is shared, so one caller's
    /// cancellation must not cancel it. Cancelling mid-exchange would strand a
    /// refresh token the server already rotated (the new one never written
    /// back) and fail every other waiter. The cancelled caller still receives
    /// the result; the provider checks cancellation after `run` returns.
    @Test("cancelling one caller neither cancels the shared flight nor fails other waiters")
    func caller_cancellation_does_not_cancel_flight() async throws {
        let flight = SingleFlight<Bool>()
        let started = Flag()
        let release = Flag()
        let operation: @Sendable () async throws -> Bool = {
            started.set()
            while !release.isSet {
                try? await Task.sleep(nanoseconds: 5_000_000) // polling; cancellation is what is observed below
            }
            return Task.isCancelled
        }
        let cancelled = Task { try await flight.run(operation) }
        for _ in 0..<400 where !started.isSet {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let joined = Task { try await flight.run(operation) }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelled.cancel()
        release.set()
        let cancelledSawCancellation = try await cancelled.value
        let joinedSawCancellation = try await joined.value
        #expect(!cancelledSawCancellation)
        #expect(!joinedSawCancellation)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
