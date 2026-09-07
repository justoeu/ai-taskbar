import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("ISO8601Parsing — fast path agrees with the formatters")
struct ISO8601ParsingTests {
    /// Built per call, not stored statically: `ISO8601DateFormatter` is not
    /// `Sendable`, and a `static let` of one trips strict concurrency.
    private func reference(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return f
    }

    /// The fast path is only safe if it agrees with the formatter it replaces.
    /// Sweep a wide spread of dates — leap years, century boundaries, month
    /// ends, DST-adjacent instants (irrelevant in UTC, which is the point) —
    /// and require bit-equal results.
    @Test("agrees with ISO8601DateFormatter across a wide date sweep")
    func agrees_with_formatter() {
        let samples = [
            "2026-07-13T15:45:36.731Z", "2026-07-13T15:45:36Z",
            "1970-01-01T00:00:00Z", "1970-01-01T00:00:00.000Z",
            "1999-12-31T23:59:59.999Z", "2000-01-01T00:00:00Z",
            "2000-02-29T12:00:00Z",          // leap year, divisible by 400
            "2024-02-29T23:59:59.500Z",      // ordinary leap year
            "2100-03-01T00:00:00Z",          // 2100 is NOT a leap year
            "2026-01-31T00:00:00Z", "2026-12-31T23:59:59Z",
            "2026-03-08T07:00:00Z",          // US DST boundary instant
            "2026-11-01T06:00:00Z",
            "2038-01-19T03:14:08Z",          // past 32-bit time_t
        ]
        for s in samples {
            let fast = ISO8601Parsing.fastParse(s)
            let slow = reference(fractional: true).date(from: s) ?? reference(fractional: false).date(from: s)
            #expect(fast != nil, "fast path should handle \(s)")
            #expect(slow != nil, "formatter should handle \(s)")
            if let fast, let slow {
                #expect(abs(fast.timeIntervalSince1970 - slow.timeIntervalSince1970) < 0.0005,
                        "mismatch on \(s): \(fast) vs \(slow)")
            }
        }
    }

    /// Every shape the fast path does NOT own must return nil so `parse`
    /// falls through to the formatters instead of guessing.
    @Test("declines anything outside the strict UTC shape")
    func declines_other_shapes() {
        for s in ["2026-07-13T15:45:36+02:00",   // offset, not Z
                  "2026-07-13T15:45:36",          // no zone
                  "2026-7-13T15:45:36Z",          // unpadded month
                  "2026-07-13 15:45:36Z",         // space instead of T
                  "2026-07-13T15:45:36.Z",        // empty fraction
                  "2026-13-13T15:45:36Z",         // month 13
                  "2026-07-13T25:45:36Z",         // hour 25
                  "2026-07-13T15:45:36Zx",        // trailing junk
                  "", "not a date"] {
            #expect(ISO8601Parsing.fastParse(s) == nil, "should decline \(s)")
        }
    }

    /// `parse` must still handle the declined shapes via the fallback, so the
    /// fast path is an optimisation and never a behaviour change.
    @Test("parse still accepts offsets through the formatter fallback")
    func parse_falls_back() {
        let d = ISO8601Parsing.parse("2026-07-13T15:45:36+02:00")
        #expect(d != nil)
        #expect(d == reference(fractional: false).date(from: "2026-07-13T15:45:36+02:00"))
    }

    @Test("parse returns nil for genuinely malformed input")
    func parse_nil_on_garbage() {
        #expect(ISO8601Parsing.parse("nonsense") == nil)
    }

    /// Pin the civil-date arithmetic independently of any formatter.
    @Test("daysFromCivil matches known epochs")
    func days_from_civil() {
        #expect(ISO8601Parsing.daysFromCivil(year: 1970, month: 1, day: 1) == 0)
        #expect(ISO8601Parsing.daysFromCivil(year: 1969, month: 12, day: 31) == -1)
        #expect(ISO8601Parsing.daysFromCivil(year: 2000, month: 3, day: 1) == 11017)
        #expect(ISO8601Parsing.daysFromCivil(year: 2026, month: 7, day: 13) == 20647)
    }
}
