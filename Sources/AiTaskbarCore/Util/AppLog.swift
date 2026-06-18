import Foundation
import os

/// Centralized `os.Logger` registry. Replaces `NSLog` calls scattered across
/// the codebase with categorized loggers under subsystem `ai-taskbar`.
///
/// Why `os.Logger` over `NSLog`:
///   - Subsystem + category namespacing makes logs filterable in Console.app
///     and `log stream`.
///   - Per-call `privacy: .private/.public` redaction keeps PII (Keychain
///     account names, TLS pin hashes) out of sysdiagnose uploads while
///     preserving useful operational hints.
///   - Structured levels (`.error`/`.info`/`.debug`) let users tune verbosity
///     via `log config` without code changes.
///
/// Conventions:
///   - Host names, counts, op names, error strings → `.public`
///   - Account names, pin hashes, credential-adjacent identifiers → `.private`
///   - Actual secrets (tokens, API keys) are NEVER logged at any level.
public enum AppLog {
    public static let keychain    = Logger(subsystem: subsystem, category: "keychain")
    public static let pinning     = Logger(subsystem: subsystem, category: "pinning")
    public static let config      = Logger(subsystem: subsystem, category: "config")
    public static let lifecycle   = Logger(subsystem: subsystem, category: "lifecycle")
    public static let updates     = Logger(subsystem: subsystem, category: "updates")
    public static let scheduler   = Logger(subsystem: subsystem, category: "scheduler")

    public static let subsystem = "ai-taskbar"
}
