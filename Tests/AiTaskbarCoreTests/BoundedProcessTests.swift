import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("BoundedProcess", .serialized)
struct BoundedProcessTests {
    @Test("a quick child returns its stdout and a clean exit")
    func happy_path() throws {
        let outcome = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/echo"),
                                             arguments: ["hello", "world"], timeout: 5)
        #expect(!outcome.timedOut)
        #expect(outcome.drained)
        #expect(outcome.terminationReason == .exit)
        #expect(outcome.status == 0)
        #expect(outcome.exitedCleanly)
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "hello world\n")
    }

    @Test("a non-zero exit keeps its status")
    func non_zero_exit() throws {
        let outcome = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                             arguments: ["-c", "exit 7"], timeout: 5)
        #expect(!outcome.timedOut)
        #expect(outcome.status == 7)
        #expect(!outcome.exitedCleanly)
    }

    @Test("a child that outlives the budget is terminated and reported as timed out")
    func timeout_kills_child() throws {
        let start = Date()
        let outcome = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                             arguments: ["30"], timeout: 0.3)
        #expect(outcome.timedOut)
        #expect(outcome.terminationReason == .uncaughtSignal)
        #expect(!outcome.exitedCleanly)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("a child that ignores SIGTERM is SIGKILLed")
    func sigkill_after_ignored_term() throws {
        let start = Date()
        let outcome = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                             arguments: ["-c", "trap '' TERM; while :; do sleep 0.05; done"],
                                             timeout: 0.3)
        #expect(outcome.timedOut)
        #expect(outcome.terminationReason == .uncaughtSignal)
        #expect(outcome.status == SIGKILL)
        #expect(Date().timeIntervalSince(start) < 6)
    }

    // BP-REP-002: the opt-in stderr capture drains concurrently with stdout.
    @Test("captured stderr is drained concurrently and kept up to its cap")
    func stderr_captured_with_cap() throws {
        let start = Date()
        let outcome = try BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "s=eeeeeeeeee; i=0; while [ $i -lt 15 ]; do s=\"$s$s\"; i=$((i+1)); done; printf '%s' \"$s\" >&2; printf ok"],
            timeout: 3,
            options: .init(stderrBytes: 1000))
        #expect(outcome.exitedCleanly)
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "ok")
        #expect(outcome.stderr.count == 1000)
        #expect(Date().timeIntervalSince(start) < 2.5)
    }

    @Test("stdout over its cap kills the child and is reported, not returned")
    func stdout_cap_rejects() throws {
        let start = Date()
        let outcome = try BoundedProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while :; do printf xxxxxxxxxxxxxxxx; done"],
            timeout: 10,
            options: .init(maximumStdoutBytes: 4096))
        #expect(outcome.stdoutExceeded)
        #expect(!outcome.timedOut)
        #expect(outcome.stdout.isEmpty)
        #expect(!outcome.exitedCleanly)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("a stdout within its cap is returned whole")
    func stdout_cap_allows_small() throws {
        let outcome = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/echo"),
                                             arguments: ["hi"], timeout: 5,
                                             options: .init(maximumStdoutBytes: 4096))
        #expect(outcome.exitedCleanly)
        #expect(!outcome.stdoutExceeded)
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "hi\n")
    }

    @Test("cancellation mid-run kills the child well before the budget")
    func cancellation_kills_child() throws {
        let token = BoundedProcess.Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { token.cancel() }
        let start = Date()
        let outcome = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                             arguments: ["30"], timeout: 20,
                                             options: .init(cancellation: token))
        #expect(outcome.cancelled)
        #expect(!outcome.timedOut)
        #expect(outcome.terminationReason == .uncaughtSignal)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("an already-cancelled token never launches the child")
    func cancelled_before_launch() {
        let token = BoundedProcess.Cancellation()
        token.cancel()
        #expect(throws: CancellationError.self) {
            try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/echo"),
                                   arguments: [], timeout: 1,
                                   options: .init(cancellation: token))
        }
    }

    @Test("a custom environment reaches the child")
    func environment_passed() throws {
        let outcome = try BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                             arguments: ["-c", "printf %s \"$B9_PROBE\""], timeout: 5,
                                             options: .init(environment: ["B9_PROBE": "yes"]))
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "yes")
    }

    @Test("a missing executable throws instead of crashing")
    func launch_failure() {
        #expect(throws: (any Error).self) {
            try BoundedProcess.run(executable: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"),
                                   arguments: [], timeout: 1)
        }
    }
}
