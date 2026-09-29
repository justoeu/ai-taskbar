import Foundation
import os

/// Runs a short-lived helper tool under one wall-clock budget. This is the only
/// copy of the launch / drain / kill logic, shared by the Keychain
/// `/usr/bin/security` read fallback and the update DMG `hdiutil` check.
///
/// - The executable is an absolute URL and the arguments are passed as an
///   array. Nothing goes through a shell.
/// - stdin is `/dev/null` and stderr is discarded. stdout is read on a
///   background thread, so a child that writes more than the pipe buffer
///   cannot deadlock against the wait.
/// - A single deadline covers both the child's exit and the stdout drain.
///   A child still running at the deadline gets SIGTERM, then SIGKILL one
///   second later.
///
/// The call is synchronous and can block for up to `timeout` + ~3 s. Callers
/// run it off the main actor and off the cooperative pool.
public enum BoundedProcess {
    public struct Outcome: Sendable {
        /// The budget lapsed before the child exited or before stdout was
        /// fully drained.
        public let timedOut: Bool
        /// stdout was read to EOF. If this is false, `stdout` is empty.
        public let drained: Bool
        /// nil while the child is still running (it survived SIGKILL's wait).
        public let terminationReason: Process.TerminationReason?
        /// The exit status, or the signal number when `terminationReason == .uncaughtSignal`.
        /// Only meaningful when `terminationReason` is non-nil.
        public let status: Int32
        public let stdout: Data

        /// Exited normally with status 0 and stdout complete. This can hold
        /// even when `timedOut` is true, if the child finished right as the
        /// budget lapsed. Callers decide whether to accept that case.
        public var exitedCleanly: Bool { drained && terminationReason == .exit && status == 0 }
    }

    /// - Throws: whatever `Process.run()` throws if the child cannot be launched.
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let output = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            let data = reader.readDataToEndOfFile()
            output.withLock { $0 = data }
            drained.signal()
        }

        let deadline = DispatchTime.now() + timeout
        let timedOut: Bool
        let drainedInTime: Bool
        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            timedOut = true
            drainedInTime = drained.wait(timeout: .now() + 1) == .success
        } else {
            drainedInTime = drained.wait(timeout: deadline) == .success
            timedOut = !drainedInTime
        }

        let running = process.isRunning
        return Outcome(timedOut: timedOut,
                       drained: drainedInTime,
                       terminationReason: running ? nil : process.terminationReason,
                       status: running ? 0 : process.terminationStatus,
                       stdout: drainedInTime ? output.withLock { $0 } : Data())
    }
}
