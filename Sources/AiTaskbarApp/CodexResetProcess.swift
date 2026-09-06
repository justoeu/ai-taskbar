import Foundation
import Darwin
import Security
import AiTaskbarCore

/// One short-lived, isolated app-server per explicit user action. Created and
/// used on a background task only; never launched by the refresh scheduler.
final class CodexResetProcess: CodexResetRPC {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let directory: URL
    private let timeout: TimeInterval
    private var nextID: Int64 = 0
    private var started = false
    private var buffer = Data()

    static var executable: URL? {
        let roots = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                     NSHomeDirectory() + "/.local/bin/codex"]
        #if arch(arm64)
        let package = "codex-darwin-arm64", target = "aarch64-apple-darwin"
        #else
        let package = "codex-darwin-x64", target = "x86_64-apple-darwin"
        #endif
        return roots.flatMap { path -> [URL] in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard resolved.lastPathComponent == "codex.js" else { return [resolved] }
            let root = resolved.deletingLastPathComponent().deletingLastPathComponent()
            return [root.appendingPathComponent("node_modules/@openai/\(package)/vendor/\(target)/bin/codex"),
                    root.deletingLastPathComponent().appendingPathComponent("\(package)/vendor/\(target)/bin/codex")]
        }.first(where: trustedExecutable)
    }

    static func trustedExecutable(_ url: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier codex and certificate leaf[subject.OU] = \"2DC432GLL2\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    init(executable: URL? = CodexResetProcess.executable,
         arguments: [String] = ["app-server", "--stdio"], timeout: TimeInterval = 15,
         validateExecutable: (URL) -> Bool = CodexResetProcess.trustedExecutable) throws {
        guard let executable, validateExecutable(executable) else { throw OpenAIResetError.unavailable }
        self.timeout = timeout
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-taskbar-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // CODEX_HOME is used for its documented purpose: an isolated Codex
        // runtime directory. Never read/modify the user's Codex configuration.
        // No inherited OPENAI_*, proxy or logging configuration can reroute tokens.
        process.environment = [
            "HOME": NSHomeDirectory(), "CODEX_HOME": directory.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "TMPDIR": directory.path, "LANG": "en_US.UTF-8"
        ]
        process.standardInput = input
        process.standardOutput = output
        // Server diagnostics can contain user data; do not forward or persist them.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            started = true
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw OpenAIResetError.unavailable
        }
        // These parent-only ends carry no user data; closing is best-effort.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // Bound teardown even if an old CLI ignores SIGTERM. This is only our
        // own Process, not a name-based kill of the user's running Codex sessions.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        while process.isRunning && ContinuousClock.now < deadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if started { process.waitUntilExit() }
        try? output.fileHandleForReading.close()
        // Best-effort cleanup is scoped to the UUID directory this instance owns.
        try? FileManager.default.removeItem(at: directory)
    }

    func notify(_ method: String) throws {
        try send(["method": .string(method)])
    }

    func request(_ method: String, params: [String: JSONValue]) throws -> [String: JSONValue] {
        nextID += 1
        let id = nextID
        try send(["id": .int(id), "method": .string(method), "params": .object(params)])
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        for _ in 0..<128 {
            let data = try readLine(until: deadline)
            let frame: [String: JSONValue]
            do { frame = try SharedCoders.decoder.decode([String: JSONValue].self, from: data) }
            catch { throw OpenAIResetError.protocolFailure }
            if frame["method"] == .string("account/chatgptAuthTokens/refresh") {
                // Renewal belongs to the user's CLI, never this monitor.
                throw OpenAIResetError.authorization
            }
            guard frame["id"] == .int(id) else { continue }
            if case .object(let error) = frame["error"] {
                if error["code"] == .int(-32601) { throw OpenAIResetError.methodNotFound }
                throw OpenAIResetError.protocolFailure
            }
            guard case .object(let result) = frame["result"] else {
                throw OpenAIResetError.protocolFailure
            }
            return result
        }
        throw OpenAIResetError.protocolFailure
    }

    private func send(_ object: [String: JSONValue]) throws {
        guard process.isRunning else { throw OpenAIResetError.unavailable }
        var data = try SharedCoders.encoder.encode(object)
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { throw OpenAIResetError.protocolFailure }
    }

    private func readLine(until deadline: ContinuousClock.Instant) throws -> Data {
        while ContinuousClock.now < deadline {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard buffer.count < 1_048_576 else { throw OpenAIResetError.protocolFailure }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                    events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw OpenAIResetError.protocolFailure }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw OpenAIResetError.protocolFailure }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        throw OpenAIResetError.timeout
    }
}

enum OpenAIResetService {
    static func prepare(path: URL) async throws -> OpenAIResetOffer {
        try await Task.detached(priority: .userInitiated) {
            let auth = try FileCredentialReader(path: path).read()
            if let pending = try OpenAIResetJournal().read() {
                guard try OpenAIResetProtocol.accountID(auth) == pending.accountID else {
                    throw OpenAIResetError.accountChanged
                }
                return pending
            }
            let rpc = try CodexResetProcess()
            return try OpenAIResetProtocol.prepare(auth: auth, rpc: rpc)
        }.value
    }

    static func consume(path: URL, offer: OpenAIResetOffer, retry: Bool) async throws -> OpenAIResetReceipt {
        try await Task.detached(priority: .userInitiated) {
            let journal = OpenAIResetJournal()
            return try journal.withExclusiveAccess {
                let existing = try journal.read()
                if let existing, existing.id != offer.id || existing.accountID != offer.accountID {
                    throw OpenAIResetError.attemptInProgress
                }
                let auth = try FileCredentialReader(path: path).read()
                let rpc = try CodexResetProcess()
                let receipt: OpenAIResetReceipt
                do {
                    receipt = try OpenAIResetProtocol.consume(auth: auth, offer: offer,
                        retry: retry || existing != nil, rpc: rpc, beforeDispatch: { try journal.save(offer) })
                } catch OpenAIResetError.consumeUnsupported {
                    try journal.rejectUnsupported(isRetry: retry || existing != nil)
                }
                do { try journal.clear() }
                catch { throw OpenAIResetError.submissionUncertain }
                return receipt
            }
        }.value
    }
}
