import Foundation

// Double -> integer conversions that never trap.
//
// `Int(_: Double)` / `Int64(_: Double)` are fatal errors for NaN, infinity
// and anything outside the integer's range. Vendor JSON, credential files,
// JWT claims and persisted history are all external input and can carry any
// finite Double (`1e300` is valid JSON; sums of large values overflow to
// infinity; `inf / inf` is NaN). Every such conversion goes through one of
// the two initializers below; bare `Int(someDouble)` on external input is a
// crash waiting for a malformed payload.
//
// Policy — pick by what the number is for:
// - `init(saturating:)` for DISPLAY and ordering: truncates toward zero like
//   `Int(_:)`, NaN becomes 0, out-of-range clamps to `.min` / `.max`. A label
//   showing a huge number is wrong but harmless; a crash is not.
// - `init?(checkedTruncating:)` for DECODED FIELDS whose absurd value means
//   "not a usable value": returns nil, so the field reads as absent.
public extension FixedWidthInteger {
    /// Saturating conversion: truncates toward zero, NaN -> 0, values beyond
    /// the type's range -> `.min` / `.max`. Never traps.
    init(saturating value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= Double(Self.max) {
            // `Double(Int64.max)` rounds UP to 2^63, which is itself out of
            // range, so `>=` (not `>`) is what keeps the fallthrough safe.
            self = .max
        } else if value <= Double(Self.min) {
            self = .min
        } else {
            self.init(value)
        }
    }

    /// Checked conversion: truncates toward zero, nil for NaN, infinity or a
    /// value the type cannot represent. Never traps.
    init?(checkedTruncating value: Double) {
        self.init(exactly: value.rounded(.towardZero))
    }

    /// Sum that sticks at `.max` / `.min` instead of wrapping: a counter
    /// summed from vendor data must never turn negative. Never traps.
    func addingSaturating(_ other: Self) -> Self {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        return other > 0 ? .max : .min
    }
}

/// The single sanitization point for utilization percentages, applied where
/// vendor numbers become `UsageWindow` / `ModelShare` and where history
/// samples are appended or loaded.
///
/// Decision: CLAMP, don't drop. NaN -> 0; everything else is clamped to
/// `0...maximum`. `maximum` is 1000 % — ten times over quota, far above any
/// overuse a vendor has reported, so no real reading changes, while an absurd
/// value (1e300, infinity) still renders as "maxed out" instead of vanishing
/// or crashing the integer formatting downstream. Negative readings carry no
/// meaning for a quota and clamp to 0.
public enum UtilizationPercent {
    public static let maximum: Double = 1000

    public static func sanitized(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return Swift.min(Swift.max(value, 0), maximum)
    }
}
