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

    @Test("a missing executable throws instead of crashing")
    func launch_failure() {
        #expect(throws: (any Error).self) {
            try BoundedProcess.run(executable: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"),
                                   arguments: [], timeout: 1)
        }
    }
}
