import Foundation

/// Runs blocking work (a Keychain read, a `/usr/bin/security` subprocess, a
/// SecurityAgent dialog waiting on the user) on a plain GCD thread and
/// resumes the async caller when it finishes. `Task.detached` is not enough:
/// it still runs on the cooperative pool, which has one thread per core, so
/// a blocked body parks one of the few threads every other task needs.
public enum OffPool {
    public static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
