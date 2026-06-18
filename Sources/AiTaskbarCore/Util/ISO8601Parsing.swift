import Foundation

/// Centralized ISO-8601 parsing for the three places that previously each
/// instantiated their own `ISO8601DateFormatter` pair (fractional + non-
/// fractional variants). `ISO8601DateFormatter` is expensive to construct
/// (it parses the format options and allocates an ICU formatter), so caching
/// two process-wide instances and exposing a single `parse(_:)` keeps the
/// hot-path wire-type decoders allocation-free.
///
/// Tries the fractional-seconds variant first (Claude session logs and some
/// Anthropic usage responses include sub-second precision), then falls back
/// to the strict `withInternetDateTime` form used by GitHub Releases, OpenAI,
/// ZAI, Kimi, etc.
public enum ISO8601Parsing {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses an ISO-8601 timestamp with or without fractional seconds.
    /// Returns nil for malformed input.
    public static func parse(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }
}
