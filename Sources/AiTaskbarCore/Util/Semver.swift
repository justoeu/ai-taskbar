import Foundation

/// Minimal semver comparison used by the update checker. Accepts versions
/// with or without a leading `v`, missing patch (treated as `0`), and
/// optional pre-release suffix (`-beta1`, `-rc.2`).
///
/// Convention: stable release > prerelease of the same base
///   v0.2.0       > v0.2.0-beta1
///   v0.2.0-beta2 > v0.2.0-beta1   (lexicographic on the suffix)
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
        case let (sa?, sb?):   return sa > sb
        }
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
