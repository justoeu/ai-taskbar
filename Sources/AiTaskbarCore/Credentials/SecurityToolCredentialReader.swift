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
///   `-s "Claude Code-cred"` → not found.
/// - A hard timeout kills the child. If the tool were ever *not* trusted on an
///   item, securityd would raise a dialog on the tool's behalf; killing the
///   child dismisses it, and a cooldown stops the next scheduled refresh from
///   flashing it again.
/// - stdin is `/dev/null`, stderr is discarded, stdout is decoded and handed
///   back as opaque bytes. Nothing is logged from the payload.
public final class SecurityToolCredentialReader: @unchecked Sendable {
    public static let defaultExecutable = URL(fileURLWithPath: "/usr/bin/security")
    public static let defaultTimeout: TimeInterval = 10
    public static let defaultCooldown: TimeInterval = 3600

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case coolingDown(until: Date)
        case launchFailed(String)
        case timedOut
        case exited(status: Int32)
        case undecodableOutput

        public var errorDescription: String? {
            switch self {
            case .coolingDown(let until):
                return "security tool fallback paused until \(until) after a hung invocation"
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
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var disabledUntil: Date?

    /// - Parameters:
    ///   - keychainPaths: explicit keychain files appended to the command
    ///     (tests point this at a temporary keychain); empty = login search list.
    ///   - timeout: seconds before the child is terminated.
    ///   - cooldown: seconds the fallback stays disabled after a timeout.
    public init(executable: URL = SecurityToolCredentialReader.defaultExecutable,
                keychainPaths: [String] = [],
                timeout: TimeInterval = SecurityToolCredentialReader.defaultTimeout,
                cooldown: TimeInterval = SecurityToolCredentialReader.defaultCooldown,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.executable = executable
        self.keychainPaths = keychainPaths
        self.timeout = timeout
        self.cooldown = cooldown
        self.now = now
    }

    /// True while a previous hung invocation keeps the fallback disabled.
    public var isCoolingDown: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let disabledUntil else { return false }
        return now() < disabledUntil
    }

    /// Exact-match `find-generic-password` invocation. A nil/empty account
    /// omits `-a`, which lets the tool pick the first item of that service —
    /// only ever used for the legacy account-less Claude item.
    public static func arguments(service: String, account: String?, keychainPaths: [String]) -> [String] {
        var args = ["find-generic-password", "-s", service]
        if let account, !account.isEmpty { args += ["-a", account] }
        args.append("-w")
        args += keychainPaths
        return args
    }

    /// `security … -w` prints the secret followed by a newline. Secrets that are
    /// not printable UTF-8 come out hex-encoded instead; both forms are handled.
    /// Returns nil for an empty answer.
    public static func decodeOutput(_ raw: Data) -> Data? {
        // Trim at the byte level: Swift folds "\r\n" into one Character.
        var bytes = raw
        while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8) else { return nil }
        if let first = text.first, first == "{" || first == "[" { return Data(text.utf8) }
        if let hex = dataFromHex(text) { return hex }
        return Data(text.utf8)
    }

    public func read(service: String, account: String?) throws -> Data {
        if let until = coolingDownUntil() { throw Failure.coolingDown(until: until) }

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
        let output = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            output.set(reader.readDataToEndOfFile())
            drained.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            _ = drained.wait(timeout: .now() + 2)
            beginCooldown()
            throw Failure.timedOut
        }
        _ = drained.wait(timeout: .now() + 2)

        guard process.terminationStatus == 0 else { throw Failure.exited(status: process.terminationStatus) }
        guard let secret = Self.decodeOutput(output.get()) else { throw Failure.undecodableOutput }
        return secret
    }

    private func coolingDownUntil() -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let disabledUntil, now() < disabledUntil else { return nil }
        return disabledUntil
    }

    private func beginCooldown() {
        lock.lock(); defer { lock.unlock() }
        disabledUntil = now().addingTimeInterval(cooldown)
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let hi = nibble(chars[index]), let lo = nibble(chars[index + 1]) else { return nil }
            data.append(hi << 4 | lo)
            index += 2
        }
        return data
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Lock-guarded byte box shared between the drain thread and the caller.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
