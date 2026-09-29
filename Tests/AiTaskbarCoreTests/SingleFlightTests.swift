import Testing
import Foundation
@testable import AiTaskbarCore
import AiTaskbarTesting

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

@Suite("SingleFlight and OffPool")
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

    @Test("OffPool.run executes on a GCD thread, not the cooperative pool")
    func offpool_leaves_cooperative_pool() async throws {
        let onPool = try await OffPool.run { CooperativePoolProbe.isOnCooperativePool }
        let detachedOnPool = await Task.detached { CooperativePoolProbe.isOnCooperativePool }.value
        #expect(!onPool)
        #expect(detachedOnPool)
    }

    @Test("OffPool.run rethrows the body's error")
    func offpool_rethrows() async {
        await #expect(throws: AppError.self) {
            try await OffPool.run { () throws -> Int in throw AppError.credentials("x") }
        }
    }
}
