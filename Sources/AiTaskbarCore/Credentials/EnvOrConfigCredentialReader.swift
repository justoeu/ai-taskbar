import Foundation
import Darwin

/// Resolves an API key from (in order): environment variable, then an inline
/// value passed via config. Used for Z.AI, OpenRouter, and Kimi.
public struct EnvOrConfigCredentialReader: Sendable {
    public let envVarName: String
    public let inlineKey: String?
    public let vendorName: String

    public init(envVarName: String, inlineKey: String?, vendorName: String) {
        self.envVarName = envVarName
        self.inlineKey = inlineKey
        self.vendorName = vendorName
    }

    public func read() throws -> String {
        // `getenv` is O(1) and doesn't materialize the full environment dict
        // like `ProcessInfo.processInfo.environment` does.
        if let rawC = getenv(envVarName),
           let env = String(validatingUTF8: rawC),
           !env.trimmingCharacters(in: .whitespaces).isEmpty {
            return env
        }
        if let inline = inlineKey?.trimmingCharacters(in: .whitespaces),
           !inline.isEmpty {
            return inline
        }
        throw AppError.disabled("""
            \(vendorName): set $\(envVarName) or add `api_key = "..."` to config.toml. \
            Note: apps launched from Finder don't inherit your shell env — \
            either put the key in config.toml or launch via `open -a`.
            """)
    }
}
