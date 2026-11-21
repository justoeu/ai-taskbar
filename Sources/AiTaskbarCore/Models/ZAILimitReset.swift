import Foundation

/// What a Z.AI "Reset Quota" record gives back. The console's two groups
/// (`docs/SDD-zai-quota-reset.md`, read from the console bundle on
/// 2026-11-21): `FIVE_HOUR` refills the 5-hour window, `WEEK` refills the
/// weekly window AND the 5-hour one, without spending a 5-hour reset.
public enum ZAIResetKind: String, Sendable, Codable, CaseIterable {
    case fiveHour = "FIVE_HOUR"
    case weekly = "WEEK"

    /// The order the console lists them in.
    public static let displayOrder: [ZAIResetKind] = [.fiveHour, .weekly]
}

/// One unused reset from `GET /api/biz/customer-package-reset/list`.
/// Allow-listed fields only: the list's `customerId`, organization and
/// project ids are never decoded.
public struct ZAIResetGrant: Sendable, Equatable, Codable {
    /// Server record id; sent back on use. Always positive (checked at decode).
    public let recordID: Int64
    public let kind: ZAIResetKind
    /// Server value echoed on use (`GLOBAL` observed). `^[A-Za-z0-9_-]{1,32}$`.
    public let grantType: String?
    /// The server's `expireTime`, `yyyy-MM-dd HH:mm:ss` with no time zone.
    /// Kept as text: it orders correctly as a string and is shown as given.
    public let expiresAt: String?

    public init(recordID: Int64, kind: ZAIResetKind, grantType: String?, expiresAt: String?) {
        self.recordID = recordID
        self.kind = kind
        self.grantType = grantType
        self.expiresAt = expiresAt
    }

    public static func isValidGrantType(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32
            && value.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-" }
    }

    /// `yyyy-MM-dd` with an optional ` HH:mm:ss`, ASCII digits, and a real
    /// calendar date (`2026-13-45` would roll over into a wrong day);
    /// anything else is dropped.
    public static func isValidExpiry(_ value: String) -> Bool {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}:[0-9]{2})?$"#,
                          options: .regularExpression) != nil else { return false }
        return expiryDate(value) != nil
    }

    /// The expiry's calendar day as a UTC midnight, nil when the date does
    /// not exist. The server gives no time zone; the day is shown as given.
    public static func expiryDate(_ value: String) -> Date? {
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let wanted = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: wanted) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == parts[0], back.month == parts[1], back.day == parts[2] else { return nil }
        if value.count > 10 {
            let time = value.dropFirst(11).split(separator: ":").compactMap { Int($0) }
            guard time.count == 3, (0...23).contains(time[0]), (0...59).contains(time[1]),
                  (0...59).contains(time[2]) else { return nil }
        }
        return date
    }

    /// The date part (`yyyy-MM-dd`), for display.
    public var expiryDay: String? { expiresAt.map { String($0.prefix(10)) } }

    /// The card windows this record refills. A weekly reset also refills the
    /// 5-hour window (the console says so; no 5-hour reset is spent).
    func windows(in snapshot: ZAISnapshot) -> [UsageWindow] {
        switch kind {
        case .fiveHour: return [snapshot.session].compactMap { $0 }
        case .weekly: return [snapshot.weekly, snapshot.session].compactMap { $0 }
        }
    }
}

/// A reset the card may offer: one per kind, aimed at one record.
public struct ZAIResetOffer: Sendable, Equatable, Identifiable {
    public let kind: ZAIResetKind
    /// The record a use spends: the one expiring first (the console's
    /// "Preferred").
    public let grant: ZAIResetGrant
    /// Unused resets of this kind.
    public let resetsLeft: Int
    public var id: ZAIResetKind { kind }

    public init(kind: ZAIResetKind, grant: ZAIResetGrant, resetsLeft: Int) {
        self.kind = kind
        self.grant = grant
        self.resetsLeft = resetsLeft
    }
}

public extension ZAISnapshot {
    /// Same rule as the Claude and OpenAI resets: an unused reset exists AND
    /// a window it refills is above 90% (strictly), finite, and not already
    /// past its own reset time.
    func limitResetOffers(now: Date = Date()) -> [ZAIResetOffer] {
        ZAIResetKind.displayOrder.compactMap { kind in
            let grants = resetGrants.filter { $0.kind == kind }
            guard let first = grants.first else { return nil }
            let needed = first.windows(in: self).contains {
                $0.utilizationPercent.isFinite && $0.utilizationPercent > 90 && !$0.isAwaitingReset(now: now)
            }
            guard needed else { return nil }
            // Missing expiry sorts last: a dated record is spent first.
            let target = grants.min { ($0.expiresAt ?? "~") < ($1.expiresAt ?? "~") } ?? first
            return ZAIResetOffer(kind: kind, grant: target, resetsLeft: grants.count)
        }
    }

    /// True when the 5-hour or weekly window is above 90%: the only time a
    /// reset can be offered, so the only time the provider reads the list.
    var hasWindowAboveResetThreshold: Bool {
        [session, weekly].compactMap { $0 }.contains {
            $0.utilizationPercent.isFinite && $0.utilizationPercent > 90
        }
    }
}
