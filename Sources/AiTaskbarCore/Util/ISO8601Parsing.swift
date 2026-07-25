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
    ///
    /// Hot path: the cost scanners call this once per assistant turn — 27k
    /// times per refresh on a real transcript set, where `ISO8601DateFormatter`
    /// was the single largest cost in the scan (867 ms, ~42% of it). Almost
    /// every one of those strings is the same rigid shape, so `fastParse`
    /// handles that shape arithmetically and the formatters remain the
    /// fallback for everything else (offsets, missing `Z`, week dates…).
    public static func parse(_ s: String) -> Date? {
        if let fast = fastParse(s) { return fast }
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    /// Parses exactly `YYYY-MM-DDTHH:MM:SS[.fff…]Z` (UTC, `Z` required).
    /// Returns nil for ANY deviation so the caller falls back to the
    /// formatters — being narrow is what makes it safe to be fast.
    static func fastParse(_ s: String) -> Date? {
        let u = s.utf8
        guard u.count >= 20 else { return nil }
        var i = u.startIndex

        // Reads `n` ASCII digits, advancing the index. Nil on any non-digit,
        // which is what rejects `2026-1-02`, `+00:00` offsets, and junk.
        func digits(_ n: Int) -> Int? {
            var value = 0
            for _ in 0..<n {
                guard i < u.endIndex else { return nil }
                let b = u[i]
                guard b >= 0x30, b <= 0x39 else { return nil }
                value = value * 10 + Int(b - 0x30)
                i = u.index(after: i)
            }
            return value
        }
        func literal(_ byte: UInt8) -> Bool {
            guard i < u.endIndex, u[i] == byte else { return false }
            i = u.index(after: i)
            return true
        }

        guard let year = digits(4), literal(0x2D),      // "-"
              let month = digits(2), literal(0x2D),
              let day = digits(2), literal(0x54),       // "T"
              let hour = digits(2), literal(0x3A),      // ":"
              let minute = digits(2), literal(0x3A),
              let second = digits(2)
        else { return nil }
        guard month >= 1, month <= 12, day >= 1, day <= 31,
              hour <= 23, minute <= 59, second <= 60     // 60 = leap second
        else { return nil }

        var fraction = 0.0
        if i < u.endIndex, u[i] == 0x2E {                // "."
            i = u.index(after: i)
            var scale = 0.1
            var sawDigit = false
            while i < u.endIndex, u[i] >= 0x30, u[i] <= 0x39 {
                fraction += Double(u[i] - 0x30) * scale
                scale /= 10
                sawDigit = true
                i = u.index(after: i)
            }
            guard sawDigit else { return nil }
        }
        // UTC only. An offset like `+02:00` deliberately falls through to the
        // formatters rather than being silently treated as Zulu.
        guard i < u.endIndex, u[i] == 0x5A else { return nil }   // "Z"
        i = u.index(after: i)
        guard i == u.endIndex else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second)
        return Date(timeIntervalSince1970: seconds + fraction)
    }

    /// Days since 1970-01-01 for a proleptic-Gregorian date. Howard Hinnant's
    /// `days_from_civil`: branch-free, exact for the range we care about, and
    /// avoids `Calendar`, which is where the formatter cost actually lives.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                     // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy             // [0, 146096]
        return era * 146_097 + doe - 719_468
    }
}
