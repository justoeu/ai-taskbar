import Foundation

/// Minimal semver comparison used by the update checker. Accepts versions
/// with or without a leading `v`, missing patch (treated as `0`), and
/// optional pre-release suffix (`-beta1`, `-rc.2`).
///
/// Convention: stable release > prerelease of the same base
///   v0.2.0       > v0.2.0-beta1
///   v0.2.0-beta2 > v0.2.0-beta1
///
/// Prerelease suffixes follow SemVer 2.0 section 11 precedence: split on
/// dots, compare numeric identifiers as integers, alphanumeric ones in ASCII
/// order, numeric below alphanumeric, and a longer list wins a tie. A
/// trailing digit run is also split off (`beta10` -> `beta`, `10`) so the
/// dotless tags this repo uses order numerically: beta10 > beta9.
public enum Semver {
    /// True when `a` represents a strictly newer version than `b`.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = parse(a)
        let pb = parse(b)
        for i in 0..<3 {
            if pa.parts[i] != pb.parts[i] {
                return pa.parts[i] > pb.parts[i]
            }
        }
        switch (pa.prerelease, pb.prerelease) {
        case (nil, nil):       return false
        case (nil, _):         return true
        case (_, nil):         return false
        case let (sa?, sb?):   return comparePrerelease(sa, sb) == .orderedDescending
        }
    }

    private enum Identifier {
        case numeric(Int)
        case alpha(String)
    }

    private static func identifiers(_ suffix: String) -> [Identifier] {
        suffix.split(separator: ".", omittingEmptySubsequences: false).flatMap { part -> [Identifier] in
            let s = String(part)
            if let n = Int(s) { return [.numeric(n)] }
            let digits = s.reversed().prefix(while: \.isASCII).prefix(while: \.isNumber).count
            if digits > 0, digits < s.count, let n = Int(s.suffix(digits)) {
                return [.alpha(String(s.dropLast(digits))), .numeric(n)]
            }
            return [.alpha(s)]
        }
    }

    private static func comparePrerelease(_ a: String, _ b: String) -> ComparisonResult {
        let ia = identifiers(a)
        let ib = identifiers(b)
        for (x, y) in zip(ia, ib) {
            switch (x, y) {
            case let (.numeric(m), .numeric(n)) where m != n:
                return m < n ? .orderedAscending : .orderedDescending
            case let (.alpha(m), .alpha(n)) where m != n:
                return m < n ? .orderedAscending : .orderedDescending
            case (.numeric, .alpha): return .orderedAscending
            case (.alpha, .numeric): return .orderedDescending
            default: continue
            }
        }
        if ia.count == ib.count { return .orderedSame }
        return ia.count < ib.count ? .orderedAscending : .orderedDescending
    }

    private struct Parsed {
        let parts: [Int]
        let prerelease: String?
    }

    private static func parse(_ raw: String) -> Parsed {
        var s = raw
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let split = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(split[0])
        let pre  = split.count > 1 ? String(split[1]) : nil
        let nums = base.split(separator: ".").map { Int($0) ?? 0 }
        let padded = nums + Array(repeating: 0, count: max(0, 3 - nums.count))
        return Parsed(parts: Array(padded.prefix(3)), prerelease: pre)
    }
}
