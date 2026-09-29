import Testing
import Foundation
import os
@testable import AiTaskbarCore
@testable import AiTaskbarProviders

/// BP-REP-002 / DUP-ECO-004 / LEAK-FAN-001 / RACE-CRO-008: the `agy` child
/// must be drained concurrently, bounded, killed on cancellation and
/// SIGKILLed when it ignores SIGTERM. Every test runs a throwaway `/bin/sh`
/// script from a temp dir, never a real `agy`.
@Suite("ProcessAntigravityExecutor bounded I/O", .serialized)
struct AntigravityExecutorProcessTests {
    /// Temp dir holding the fake `agy` and the pid file it writes.
    private struct FakeAgy {
        let dir: URL
        let script: String
        let pidFile: URL

        init(body: String) throws {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ai-taskbar-agy-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            pidFile = dir.appendingPathComponent("pid")
            script = dir.appendingPathComponent("agy").path
            let text = "#!/bin/sh\necho $$ > '\(pidFile.path)'\n\(body)\n"
            try text.write(toFile: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        }

        var pid: pid_t? {
            guard let s = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
            return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// Test cleanup only: a leftover child from a RED run is SIGKILLed so
        /// the suite never leaks it.
        func cleanUp() {
            if let pid, kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: dir) // best-effort temp cleanup
        }
    }

    private final class Box: Sendable {
        let state = OSAllocatedUnfairLock<Result<Data, any Error>?>(initialState: nil)
    }

    /// Polls for the task's result so a hanging executor fails the test
    /// instead of hanging the suite.
    private func result(of box: Box, within seconds: Double) async -> Result<Data, any Error>? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let r = box.state.withLock({ $0 }) { return r }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return box.state.withLock { $0 }
    }

    private func start(_ exec: ProcessAntigravityExecutor) -> (Box, Task<Void, Never>) {
        let box = Box()
        let task = Task {
            do {
                let data = try await exec.fetchUsageJSON()
                box.state.withLock { $0 = .success(data) }
            } catch {
                box.state.withLock { $0 = .failure(error) }
            }
        }
        return (box, task)
    }

    private func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    /// 327,680 bytes of `e`, produced by shell builtins only so the script
    /// has no child processes that could outlive it.
    private static let bigString = "s=eeeeeeeeee; i=0; while [ $i -lt 15 ]; do s=\"$s$s\"; i=$((i+1)); done"

    @Test("more than 128 KB on stderr does not stall the read until the timeout")
    func large_stderr_completes_promptly() async throws {
        let fake = try FakeAgy(body: """
        \(Self.bigString)
        printf '%s' "$s" >&2
        printf '%s' '{"ok":true}'
        """)
        defer { fake.cleanUp() }
        let started = Date()
        let (box, _) = start(ProcessAntigravityExecutor(customPath: fake.script, timeout: 3))
        let outcome = await result(of: box, within: 8)
        let elapsed = Date().timeIntervalSince(started)
        var body = ""
        if case .success(let data)? = outcome { body = String(decoding: data, as: UTF8.self) }
        #expect(body == #"{"ok":true}"#, "outcome: \(String(describing: outcome))")
        #expect(elapsed < 2.5)
    }

    @Test("cancelling the refresh kills the agy child")
    func cancellation_kills_child() async throws {
        let fake = try FakeAgy(body: "exec /bin/sleep 30")
        defer { fake.cleanUp() }
        let (box, task) = start(ProcessAntigravityExecutor(customPath: fake.script, timeout: 20))
        var waited = 0
        while fake.pid == nil && waited < 250 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        let pid = try #require(fake.pid)
        task.cancel()
        let outcome = await result(of: box, within: 3)
        var cancelled = false
        if case .failure(let error)? = outcome { cancelled = error is CancellationError }
        #expect(cancelled, "outcome: \(String(describing: outcome))")
        #expect(isGone(pid))
    }

    @Test("a child that ignores SIGTERM is SIGKILLed at the deadline")
    func sigterm_ignored_escalates_to_sigkill() async throws {
        let fake = try FakeAgy(body: "trap '' TERM\nwhile :; do sleep 0.05; done")
        defer { fake.cleanUp() }
        let (box, _) = start(ProcessAntigravityExecutor(customPath: fake.script, timeout: 0.5))
        let outcome = await result(of: box, within: 6)
        var timedOut = false
        if case .failure(let error)? = outcome {
            timedOut = (error as? AppError) == .guidance(.antigravityTimedOut)
        }
        #expect(timedOut, "outcome: \(String(describing: outcome))")
        let pid = try #require(fake.pid)
        #expect(isGone(pid))
    }

    @Test("stdout larger than the cap is rejected instead of buffered")
    func oversized_stdout_rejected() async throws {
        let fake = try FakeAgy(body: "\(Self.bigString)\nprintf '%s' \"$s\"")
        defer { fake.cleanUp() }
        let (box, _) = start(ProcessAntigravityExecutor(customPath: fake.script, timeout: 5,
                                                        maximumOutputBytes: 64 * 1024))
        let outcome = await result(of: box, within: 8)
        var message = ""
        if case .failure(let error)? = outcome, case .io(let m)? = error as? AppError { message = m }
        #expect(message.contains("exceeds 65536 bytes"), "outcome: \(String(describing: outcome))")
    }

    @Test("stderr noise under the cap still maps to the not-logged-in guidance")
    func stderr_still_classified() async throws {
        let fake = try FakeAgy(body: "echo 'Error: not logged in' >&2\nexit 1")
        defer { fake.cleanUp() }
        let (box, _) = start(ProcessAntigravityExecutor(customPath: fake.script, timeout: 5))
        let outcome = await result(of: box, within: 8)
        var guidance = false
        if case .failure(let error)? = outcome {
            guidance = (error as? AppError) == .guidance(.antigravityNotAuthenticated)
        }
        #expect(guidance)
    }
}
