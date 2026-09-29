import Foundation
import AiTaskbarCore
import os

/// Abstraction for invoking the Antigravity CLI (`agy`).
///
/// Abstracted behind a protocol to allow deterministic unit testing of the
/// Gemini provider without depending on a real `agy` executable or network.
public protocol AntigravityExecuting: Sendable {
    /// Returns true if an accessible `agy` executable is found.
    func isInstalled() -> Bool

    /// Executes `agy --output-format json --print "/usage"` and returns the raw JSON payload.
    func fetchUsageJSON() async throws -> Data
}

/// Production implementation that locates and invokes `agy` via `Process`.
public struct ProcessAntigravityExecutor: AntigravityExecuting {
    public let customPath: String?
    /// Wall-clock budget for one `agy` run.
    public let timeout: TimeInterval
    /// Largest stdout accepted from `agy`; more is rejected, not parsed.
    public let maximumOutputBytes: Int

    public init(customPath: String? = nil,
                timeout: TimeInterval = 35,
                maximumOutputBytes: Int = 4 * 1024 * 1024) {
        self.customPath = customPath
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    /// Resolves the URL to the `agy` binary. Checks customPath, then standard
    /// install locations (`~/.local/bin/agy`, `/opt/homebrew/bin/agy`, `/usr/local/bin/agy`,
    /// `~/.gemini/antigravity/bin/agy`).
    public var resolvedExecutableURL: URL? {
        let fm = FileManager.default
        if let custom = customPath, !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
            home.appendingPathComponent(".gemini/antigravity/bin/agy")
        ]
        for url in candidates {
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public func isInstalled() -> Bool {
        resolvedExecutableURL != nil
    }

    public func fetchUsageJSON() async throws -> Data {
        guard let exe = resolvedExecutableURL else {
            throw AppError.guidance(.antigravityNotFound)
        }

        // Ensure PATH includes the directories where agy and its tools live
        var env = ProcessInfo.processInfo.environment
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let currentPath = env["PATH"] ?? ""
        let extraPaths = "\(homePath)/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = currentPath.isEmpty ? extraPaths : "\(extraPaths):\(currentPath)"

        // BoundedProcess drains stdout and stderr concurrently (no two-pipe
        // deadlock), caps both, and escalates SIGTERM to SIGKILL. The
        // cancellation handler kills the child when the refresh is cancelled.
        let options = BoundedProcess.Options(environment: env,
                                             stderrBytes: Self.stderrBytes,
                                             maximumStdoutBytes: maximumOutputBytes,
                                             cancellation: BoundedProcess.Cancellation())
        let timeout = self.timeout
        let outcome: BoundedProcess.Outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try BoundedProcess.run(
                            executable: exe,
                            arguments: ["--output-format", "json", "--print", "/usage"],
                            timeout: timeout,
                            options: options))
                    } catch is CancellationError {
                        continuation.resume(throwing: CancellationError())
                    } catch {
                        continuation.resume(throwing: AppError.io("Failed to run agy: \(error.localizedDescription)"))
                    }
                }
            }
        } onCancel: {
            options.cancellation?.cancel()
        }
        if outcome.cancelled { throw CancellationError() }
        return try classify(outcome)
    }

    /// stderr is only mined for an error message; keep its head, drop the rest.
    static let stderrBytes = 64 * 1024

    private func classify(_ outcome: BoundedProcess.Outcome) throws -> Data {
        if outcome.stdoutExceeded {
            throw AppError.io("agy output exceeds \(maximumOutputBytes) bytes")
        }
        if outcome.timedOut || !outcome.drained {
            throw AppError.guidance(.antigravityTimedOut)
        }
        let outData = outcome.stdout
        let errData = outcome.stderr
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        let outStr = String(data: outData, encoding: .utf8) ?? ""

        // Extract clean error message from structured agy JSON if available
        let structuredError = Self.extractStructuredError(outData: outData, errData: errData)

        if outcome.status != 0 || outcome.terminationReason != .exit || structuredError != nil {
            let fullErr = [structuredError, errStr, outStr].compactMap { $0 }.joined(separator: " ")
            if fullErr.contains("not logged in") || fullErr.contains("UNAUTHENTICATED") || fullErr.contains("error getting token source") {
                throw AppError.guidance(.antigravityNotAuthenticated)
            } else if fullErr.contains("UNAVAILABLE") || fullErr.contains("unavailable") {
                throw AppError.guidance(.antigravityUnavailable)
            } else if let structured = structuredError {
                if structured == "context canceled" {
                    throw AppError.guidance(.antigravityCanceled)
                }
                throw AppError.io("agy: \(structured)")
            }
            let raw = errStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? outStr.trimmingCharacters(in: .whitespacesAndNewlines)
                : errStr.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = raw.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? raw
            let clean = firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
            throw AppError.io("agy failed (exit \(outcome.status)): \(clean)")
        }

        if outStr.contains("not logged in") || outStr.contains("error getting token source") {
            throw AppError.guidance(.antigravityNotAuthenticated)
        }
        return outData
    }

    private static func extractStructuredError(outData: Data, errData: Data) -> String? {
        struct AgyEnvelope: Decodable {
            let status: String?
            let error: String?
            let response: String?
        }

        func inspect(_ data: Data) -> String? {
            if let env = try? SharedCoders.decoder.decode(AgyEnvelope.self, from: data) {
                if env.status == "ERROR" || (env.error != nil && !(env.error?.isEmpty ?? true)) {
                    if let err = env.error, !err.isEmpty { return err }
                    if let resp = env.response, !resp.isEmpty { return resp }
                    return "agy reported an error"
                }
            }
            let str = String(data: data, encoding: .utf8) ?? ""
            if let start = str.firstIndex(of: "{"),
               let end = str.lastIndex(of: "}") {
                let sub = String(str[start...end])
                if let subData = sub.data(using: .utf8),
                   let env = try? SharedCoders.decoder.decode(AgyEnvelope.self, from: subData) {
                    if env.status == "ERROR" || (env.error != nil && !(env.error?.isEmpty ?? true)) {
                        if let err = env.error, !err.isEmpty { return err }
                        if let resp = env.response, !resp.isEmpty { return resp }
                        return "agy reported an error"
                    }
                }
            }
            return nil
        }

        return inspect(outData) ?? inspect(errData)
    }
}
