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

    public init(customPath: String? = nil) {
        self.customPath = customPath
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
            throw AppError.credentials(
                "Para conseguir monitorar o Gemini, é necessário ter o Antigravity instalado e autenticado. O executável 'agy' não foi encontrado."
            )
        }

        let process = Process()
        process.executableURL = exe
        process.arguments = ["--output-format", "json", "--print", "/usage"]
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Ensure PATH includes the directories where agy and its tools live
        var env = ProcessInfo.processInfo.environment
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let currentPath = env["PATH"] ?? ""
        let extraPaths = "\(homePath)/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = currentPath.isEmpty ? extraPaths : "\(extraPaths):\(currentPath)"
        process.environment = env

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let timedOut = OSAllocatedUnfairLock(initialState: false)
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
                timer.schedule(deadline: .now() + 35)
                timer.setEventHandler {
                    timedOut.withLock { $0 = true }
                    if process.isRunning {
                        process.terminate()
                    }
                }
                timer.resume()

                do {
                    try process.run()
                } catch {
                    timer.cancel()
                    continuation.resume(throwing: AppError.io("Failed to run agy: \(error.localizedDescription)"))
                    return
                }

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()

                if timedOut.withLock({ $0 }) {
                    continuation.resume(throwing: AppError.io("Tempo limite esgotado ao consultar o Antigravity (agy). Tente novamente."))
                    return
                }

                let errStr = String(data: errData, encoding: .utf8) ?? ""
                let outStr = String(data: outData, encoding: .utf8) ?? ""

                // Extract clean error message from structured agy JSON if available
                let structuredError = Self.extractStructuredError(outData: outData, errData: errData)

                if process.terminationStatus != 0 || structuredError != nil {
                    let fullErr = [structuredError, errStr, outStr].compactMap { $0 }.joined(separator: " ")
                    if fullErr.contains("not logged in") || fullErr.contains("UNAUTHENTICATED") || fullErr.contains("error getting token source") {
                        continuation.resume(throwing: AppError.http(status: 401, body: "Antigravity não autenticado. Execute 'agy' no Terminal para fazer login."))
                    } else if fullErr.contains("UNAVAILABLE") || fullErr.contains("unavailable") {
                        continuation.resume(throwing: AppError.http(status: 503, body: "Serviço do Google Antigravity temporariamente indisponível. Tente novamente."))
                    } else if let structured = structuredError {
                        if structured == "context canceled" {
                            continuation.resume(throwing: AppError.io("Operação cancelada ou tempo limite esgotado pelo Antigravity."))
                        } else {
                            continuation.resume(throwing: AppError.io("agy: \(structured)"))
                        }
                    } else {
                        let raw = errStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? outStr.trimmingCharacters(in: .whitespacesAndNewlines)
                            : errStr.trimmingCharacters(in: .whitespacesAndNewlines)
                        let firstLine = raw.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? raw
                        let clean = firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
                        continuation.resume(throwing: AppError.io("agy falhou (código \(process.terminationStatus)): \(clean)"))
                    }
                    return
                }

                if outStr.contains("not logged in") || outStr.contains("error getting token source") {
                    continuation.resume(throwing: AppError.http(status: 401, body: "Antigravity não autenticado. Execute 'agy' no Terminal para fazer login."))
                    return
                }

                continuation.resume(returning: outData)
            }
        }
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
                    return "Erro no Antigravity"
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
                        return "Erro no Antigravity"
                    }
                }
            }
            return nil
        }

        return inspect(outData) ?? inspect(errData)
    }
}
