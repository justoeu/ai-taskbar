import Foundation
import os

/// Coalesces concurrent callers onto one in-flight operation. The OAuth
/// providers use it so overlapping fetches share one refresh-token exchange:
/// both vendors rotate the refresh token on every exchange, so a second
/// exchange spends a token the first one already consumed.
///
/// The operation's Task is created and stored inside the same critical
/// section, so no caller can start a second one between the check and the
/// install. A finished flight clears the slot only if the slot still holds
/// that same flight.
public final class SingleFlight<Value: Sendable>: Sendable {
    private struct Flight: Sendable {
        let id: UInt64
        let task: Task<Value, Error>
    }

    private struct State: Sendable {
        var nextID: UInt64 = 0
        var flight: Flight?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func run(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let task: Task<Value, Error> = state.withLock { state in
            if let flight = state.flight { return flight.task }
            state.nextID &+= 1
            let id = state.nextID
            let task = Task<Value, Error> { [self] in
                defer { finish(id) }
                return try await operation()
            }
            state.flight = Flight(id: id, task: task)
            return task
        }
        return try await task.value
    }

    private func finish(_ id: UInt64) {
        state.withLock { state in
            if state.flight?.id == id { state.flight = nil }
        }
    }
}
