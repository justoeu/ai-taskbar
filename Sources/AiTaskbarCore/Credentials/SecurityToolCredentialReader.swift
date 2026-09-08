import Foundation
import os

/// Reads a generic-password secret through Apple's `/usr/bin/security` tool.
///
/// Why this exists: the Claude Code CLI writes `Claude Code-credentials` with
/// that very tool, so `/usr/bin/security` is always on the item's trusted-app
/// list and its `apple-tool:` partition. AI Taskbar's own identity is only on
/// that list after the user clicks Authorize, and an ad-hoc (per-build
/// `cdhash`) signature is a *different* identity every rebuild — which is how
/// one machine accumulated 36 dead authorizations and a password prompt per
/// build. Delegating the read to the tool the CLI already trusts sidesteps the
/// app's own signature entirely. It is a **read-only fallback**: the direct
/// `SecItemCopyMatching` path stays primary, and `writeBack` never uses it.
///
/// Guardrails:
/// - Exact-match arguments only (`-s service -a account`); the tool matches
///   attributes exactly — verified against the substring probe
///   `-s "Claude Code-cred"` → not found — and getopt consumes a leading-dash
///   value as the option's argument, never as a new option.
/// - One wall-clock budget (`timeout`) covers the child's lifetime *and* the
///   stdout drain; a hung child is terminated, then killed. If the tool were
///   ever *not* trusted on an item, securityd would raise a dialog on the
///   tool's behalf; killing the child dismisses it, and a long cooldown stops
///   the next scheduled refresh from flashing it again. Ordinary failures
///   (non-zero exit, no output) get a shorter cooldown so a broken fallback
///   is retried once per refresh interval instead of once per read.
/// - stdin is `/dev/null`, stderr is discarded, stdout is decoded and handed
///   back as opaque bytes. Nothing is logged from the payload.
///
/// The read is synchronous and blocks its calling thread for up to `timeout`;
/// call it from a plain thread (see `AnthropicCredentialReading.readOffPool`),
/// never from the main actor or a cooperative-pool task.
public final class SecurityToolCredentialReader: Sendable {
    public static let defaultExecutable = URL(fileURLWithPath: "/usr/bin/security")
    /// The tool normally answers in tens of milliseconds; anything slower
    /// means securityd is waiting on a human.
    public static let defaultTimeout: TimeInterval = 5
    public static let defaultTimeoutCooldown: TimeInterval = 3600
    public static let defaultFailureCooldown: TimeInterval = 300

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case coolingDown(until: Date)
        case launchFailed(String)
        case timedOut
        case exited(status: Int32)
        case undecodableOutput

        public var errorDescription: String? {
            switch self {
            case .coolingDown(let until):
                return "security tool fallback paused until \(until) after a previous failure"
            case .launchFailed(let reason):
                return "could not launch /usr/bin/security: \(reason)"
            case .timedOut:
                return "/usr/bin/security did not answer in time (possible blocked dialog); fallback paused"
            case .exited(let status):
                return "/usr/bin/security exited with status \(status)"
            case .undecodableOutput:
                return "/usr/bin/security printed no usable secret"
            }
        }
    }

    private let executable: URL
    private let keychainPaths: [String]
    private let timeout: TimeInterval
    private let timeoutCooldown: TimeInterval
    private let failureCooldown: TimeInterval
    private let now: @Sendable () -> Date
    private let disabledUntil = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// - Parameters:
    ///   - keychainPaths: explicit keychain files appended to the command
    ///     (tests point this at a temporary keychain); empty = login search list.
    ///   - timeout: total seconds the read may block, child and drain included.
    ///   - timeoutCooldown: seconds the fallback stays disabled after a hang.
    ///   - failureCooldown: seconds it stays disabled after any other failure.
    public init(executable: URL = SecurityToolCredentialReader.defaultExecutable,
                keychainPaths: [String] = [],
                timeout: TimeInterval = SecurityToolCredentialReader.defaultTimeout,
                timeoutCooldown: TimeInterval = SecurityToolCredentialReader.defaultTimeoutCooldown,
                failureCooldown: TimeInterval = SecurityToolCredentialReader.defaultFailureCooldown,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.executable = executable
        self.keychainPaths = keychainPaths
        self.timeout = timeout
        self.timeoutCooldown = timeoutCooldown
        self.failureCooldown = failureCooldown
        self.now = now
    }

    /// True while a previous failure keeps the fallback disabled.
    public var isCoolingDown: Bool { coolingDownUntil() != nil }

    /// Exact-match `find-generic-password` invocation. `-a` is always passed:
    /// `-a ""` matches only the legacy account-less item, whereas omitting
    /// `-a` would let the tool return the first item of that service.
    public static func arguments(service: String, account: String?, keychainPaths: [String]) -> [String] {
        ["find-generic-password", "-s", service, "-a", account ?? "", "-w"] + keychainPaths
    }

    /// `security … -w` prints the secret followed by a newline. Secrets that
    /// are not printable UTF-8 come out hex-encoded instead. Hex is only
    /// undone when the decoded bytes are themselves a JSON document, so an
    /// all-hex printable secret can never be mangled. Returns nil for an
    /// empty or non-UTF-8 answer.
    public static func decodeOutput(_ raw: Data) -> Data? {
        // Trim at the byte level: Swift folds "\r\n" into one Character.
        var bytes = raw
        while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8) else { return nil }
        if looksLikeJSON(bytes) { return bytes }
        if let hex = PartitionListCodec.dataFromHex(text), looksLikeJSON(hex) { return hex }
        return bytes
    }

    /// - Parameter keychainPaths: overrides the instance default so the caller
    ///   can pin the very keychain the item's persistent reference came from.
    public func read(service: String, account: String?, keychainPaths: [String]? = nil) throws -> Data {
        if let until = coolingDownUntil() { throw Failure.coolingDown(until: until) }
        do {
            return try runTool(service: service, account: account,
                               keychainPaths: keychainPaths ?? self.keychainPaths)
        } catch Failure.timedOut {
            beginCooldown(timeoutCooldown)
            throw Failure.timedOut
        } catch {
            beginCooldown(failureCooldown)
            throw error
        }
    }

    private func runTool(service: String, account: String?, keychainPaths: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(service: service, account: account, keychainPaths: keychainPaths)
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        // Drain stdout concurrently so a child that writes more than the pipe
        // buffer can never deadlock against our wait below.
        let output = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            let data = reader.readDataToEndOfFile()
            output.withLock { $0 = data }
            drained.signal()
        }

        // One deadline for everything: child exit, then drain.
        let deadline = DispatchTime.now() + timeout
        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            let drainedInTime = drained.wait(timeout: .now() + 1) == .success
            // Race window: the child may have finished cleanly right as the
            // budget lapsed. A complete, decodable answer is a success, not an
            // hour-long outage.
            if drainedInTime, !process.isRunning, process.terminationReason == .exit,
               process.terminationStatus == 0,
               let secret = Self.decodeOutput(output.withLock { $0 }) {
                return secret
            }
            throw Failure.timedOut
        }
        guard drained.wait(timeout: deadline) == .success else { throw Failure.timedOut }

        guard process.terminationStatus == 0 else { throw Failure.exited(status: process.terminationStatus) }
        guard let secret = Self.decodeOutput(output.withLock { $0 }) else { throw Failure.undecodableOutput }
        return secret
    }

    private func coolingDownUntil() -> Date? {
        let current = now()
        return disabledUntil.withLock { until in
            guard let until, current < until else { return nil }
            return until
        }
    }

    private func beginCooldown(_ seconds: TimeInterval) {
        let until = now().addingTimeInterval(seconds)
        disabledUntil.withLock { $0 = until }
    }

    private static func looksLikeJSON(_ bytes: Data) -> Bool {
        guard let first = bytes.first(where: { $0 != 0x20 && $0 != 0x09 }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }
}
