import Foundation
import os

/// Runs a short-lived helper tool under one wall-clock budget. This is the only
/// copy of the launch / drain / kill logic, shared by the Keychain
/// `/usr/bin/security` read fallback, the update DMG `hdiutil` check and the
/// Antigravity `agy` usage call.
///
/// - The executable is an absolute URL and the arguments are passed as an
///   array. Nothing goes through a shell.
/// - stdin is `/dev/null`. stderr is discarded unless `Options.stderrBytes`
///   asks for it. Each captured stream is read on its own background thread,
///   so a child that fills either pipe buffer cannot deadlock against the
///   wait or against the other stream.
/// - A single deadline covers both the child's exit and the drains. A child
///   still running at the deadline, cancelled, or over its stdout cap gets
///   SIGTERM, then SIGKILL one second later.
/// - Only the direct child is signalled: Foundation's `Process` has no
///   process-group control. A grandchild that inherited a pipe can keep its
///   write end open after the child is gone, so the drains poll instead of
///   blocking in read(2), and `run` abandons them before returning: each
///   reader stops within one poll slice and closes its read end, and the
///   grandchild gets EPIPE on its next write (LEAK-MAE-002).
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
        /// At most `Options.stderrBytes` of stderr; empty when not captured.
        public var stderr = Data()
        /// stdout went over `Options.maximumStdoutBytes`; the child was
        /// killed and `stdout` is empty.
        public var stdoutExceeded = false
        /// `Options.cancellation` fired; the child was killed.
        public var cancelled = false

        /// Exited normally with status 0 and stdout complete. This can hold
        /// even when `timedOut` is true, if the child finished right as the
        /// budget lapsed. Callers decide whether to accept that case.
        public var exitedCleanly: Bool { drained && terminationReason == .exit && status == 0 }
    }

    /// Thread-safe flag a caller flips (e.g. from a task cancellation
    /// handler) to make a running `run` kill its child.
    public final class Cancellation: Sendable {
        private let flag = OSAllocatedUnfairLock(initialState: false)
        public init() {}
        public func cancel() { flag.withLock { $0 = true } }
        public var isCancelled: Bool { flag.withLock { $0 } }
    }

    /// Opt-in extras. The defaults reproduce the original behavior exactly.
    public struct Options: Sendable {
        /// Child environment; nil inherits ours.
        public var environment: [String: String]?
        /// Keep up to this many bytes of stderr (the rest is drained and
        /// dropped); nil sends stderr to `/dev/null`.
        public var stderrBytes: Int?
        /// Reject stdout past this many bytes; nil is unbounded.
        public var maximumStdoutBytes: Int?
        public var cancellation: Cancellation?

        public init(environment: [String: String]? = nil,
                    stderrBytes: Int? = nil,
                    maximumStdoutBytes: Int? = nil,
                    cancellation: Cancellation? = nil) {
            self.environment = environment
            self.stderrBytes = stderrBytes
            self.maximumStdoutBytes = maximumStdoutBytes
            self.cancellation = cancellation
        }
    }

    /// - Throws: `CancellationError` when already cancelled, otherwise
    ///   whatever `Process.run()` throws if the child cannot be launched.
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                           options: Options = Options()) throws -> Outcome {
        if options.cancellation?.isCancelled == true { throw CancellationError() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment = options.environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = options.stderrBytes == nil ? nil : Pipe()
        process.standardError = stderr ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let exceeded = OSAllocatedUnfairLock(initialState: false)
        let out = drain(stdout.fileHandleForReading, keep: options.maximumStdoutBytes,
                        onOverflow: { exceeded.withLock { $0 = true } })
        let err = stderr.map { drain($0.fileHandleForReading, keep: options.stderrBytes, onOverflow: nil) }

        // Polling is only needed when something other than exit can end the
        // wait; without it this is the original single blocking wait.
        let stop: (() -> Bool)? = options.cancellation == nil && options.maximumStdoutBytes == nil
            ? nil
            : { options.cancellation?.isCancelled == true || exceeded.withLock { $0 } }

        let deadline = DispatchTime.now() + timeout
        let timedOut: Bool
        let drainedInTime: Bool
        if wait(exited, until: deadline, stop: stop) != .signalled {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            // No stop predicate (nil) or one that did not fire means the
            // deadline killed the child; a fired stop is cancellation or a
            // stdout overflow, reported through their own flags instead.
            timedOut = stop?() != true
            let tail = DispatchTime.now() + 1
            drainedInTime = out.done.wait(timeout: tail) == .success
                && (err?.done.wait(timeout: tail) ?? .success) == .success
        } else {
            drainedInTime = wait(out.done, until: deadline, stop: stop) == .signalled
                && (err.map { wait($0.done, until: deadline, stop: stop) } ?? .signalled) == .signalled
            // Same reading of `stop` as above.
            timedOut = !drainedInTime && stop?() != true
        }

        let running = process.isRunning
        let overflow = exceeded.withLock { $0 }
        var outcome = Outcome(timedOut: timedOut,
                              drained: drainedInTime && !overflow,
                              terminationReason: running ? nil : process.terminationReason,
                              status: running ? 0 : process.terminationStatus,
                              stdout: drainedInTime && !overflow ? out.data.withLock { $0 } : Data())
        outcome.stderr = err?.data.withLock { $0 } ?? Data()
        outcome.stdoutExceeded = overflow
        outcome.cancelled = options.cancellation?.isCancelled == true
        // Everything the outcome needs has been read. A drain still running
        // here is held open by a grandchild; stop it rather than leak it.
        out.abandon()
        err?.abandon()
        return outcome
    }

    private struct Drain: Sendable {
        let data: OSAllocatedUnfairLock<Data>
        let done: DispatchSemaphore
        let abandoned: OSAllocatedUnfairLock<Bool>

        func abandon() { abandoned.withLock { $0 = true } }
        var isAbandoned: Bool { abandoned.withLock { $0 } }
    }

    /// How long one poll(2) waits before the reader re-checks `abandoned`.
    private static let pollSliceMilliseconds: Int32 = 50

    /// Reads `handle` to EOF on a background thread. With `keep == nil` the
    /// whole stream is kept (original behavior). Otherwise only `keep` bytes
    /// are kept: with `onOverflow` the read stops and reports the overflow,
    /// without it the excess is read and dropped so the child never blocks.
    /// The read polls in `pollSliceMilliseconds` slices so `abandon()` ends
    /// it even while a grandchild holds the write end open; the read end is
    /// closed on every exit.
    private static func drain(_ handle: FileHandle, keep: Int?,
                              onOverflow: (@Sendable () -> Void)?) -> Drain {
        let result = Drain(data: OSAllocatedUnfairLock(initialState: Data()),
                           done: DispatchSemaphore(value: 0),
                           abandoned: OSAllocatedUnfairLock(initialState: false))
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                // Best-effort: the fd is ours alone and nothing reads it after
                // this point; closing is what releases a grandchild-held pipe.
                try? handle.close()
                result.done.signal()
            }
            let fd = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var kept = Data()
            while !result.isAbandoned {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, pollSliceMilliseconds)
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    break
                }
                if n == 0 { break } // EOF: every writer closed its end.
                if let keep, kept.count + n > keep {
                    if let onOverflow {
                        onOverflow()
                        return
                    }
                    kept.append(contentsOf: buffer[0..<(keep - kept.count)])
                } else {
                    kept.append(contentsOf: buffer[0..<n])
                }
            }
            let final = kept
            result.data.withLock { $0 = final }
        }
        return result
    }

    private enum WaitResult { case signalled, deadline, stopped }

    private static func wait(_ semaphore: DispatchSemaphore, until deadline: DispatchTime,
                             stop: (() -> Bool)?) -> WaitResult {
        guard let stop else {
            return semaphore.wait(timeout: deadline) == .success ? .signalled : .deadline
        }
        while true {
            if stop() { return .stopped }
            let now = DispatchTime.now()
            if now >= deadline { return .deadline }
            let slice = min(deadline, now + .milliseconds(25))
            if semaphore.wait(timeout: slice) == .success { return .signalled }
        }
    }
}
