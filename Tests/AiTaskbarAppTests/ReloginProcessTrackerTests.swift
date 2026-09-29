import Testing
import Foundation
@testable import AiTaskbarApp

private final class FakeHandle: ReloginProcessHandle {
    var isRunning = true
    private(set) var terminateCalls = 0
    func terminate() { terminateCalls += 1; isRunning = false }
}

/// LEAK-FAN-005: repeated Re-login clicks must not stack login CLIs.
@Suite("ReloginProcessTracker — one re-login child per vendor")
@MainActor
struct ReloginProcessTrackerTests {
    private struct SpawnFailed: Error {}

    private func tracker(_ handles: [FakeHandle]) -> (ReloginProcessTracker, () -> [String]) {
        var queue = handles
        var commands: [String] = []
        let t = ReloginProcessTracker(launch: { cmd in
            commands.append(cmd)
            guard !queue.isEmpty else { throw SpawnFailed() }
            return queue.removeFirst()
        })
        return (t, { commands })
    }

    @Test("a second spawn terminates the first")
    func second_spawn_terminates_first() throws {
        let first = FakeHandle(), second = FakeHandle()
        let (t, _) = tracker([first, second])
        try t.start(command: "claude /login")
        try t.start(command: "claude /login")
        #expect(first.terminateCalls == 1)
        #expect(second.terminateCalls == 0)
        #expect(t.current === second)
    }

    @Test("the command is handed to the launcher verbatim")
    func passes_command() throws {
        let (t, commands) = tracker([FakeHandle()])
        try t.start(command: "codex login")
        #expect(commands() == ["codex login"])
    }

    @Test("stop terminates a running child and forgets it")
    func stop_terminates() throws {
        let h = FakeHandle()
        let (t, _) = tracker([h])
        try t.start(command: "x")
        t.stop()
        #expect(h.terminateCalls == 1)
        #expect(t.current == nil)
    }

    @Test("an already-exited child is not signalled")
    func exited_child_not_terminated() throws {
        let h = FakeHandle()
        let (t, _) = tracker([h])
        try t.start(command: "x")
        h.isRunning = false
        t.stop()
        #expect(h.terminateCalls == 0)
    }

    @Test("a failed spawn rethrows and tracks nothing")
    func failed_spawn() {
        let (t, _) = tracker([])
        #expect(throws: SpawnFailed.self) { try t.start(command: "x") }
        #expect(t.current == nil)
    }
}
