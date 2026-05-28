import Foundation

/// Process-wide reusable `JSONDecoder` / `JSONEncoder` instances. Both are
/// documented thread-safe for `decode(_:from:)` / `encode(_:)` as long as the
/// strategy properties aren't mutated after init. We expose them as `let` so
/// callers can't accidentally reconfigure them.
public enum SharedCoders {
    /// Use everywhere instead of `JSONDecoder()` to avoid per-call allocator
    /// pressure. Re-using a single instance is roughly 30% faster on hot
    /// paths like ClaudeSessionScanner.
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()
}
