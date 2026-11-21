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

    /// `yyyy-MM-dd` with an optional ` HH:mm:ss`; anything else is dropped.
    public static func isValidExpiry(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}:\d{2})?$"#, options: .regularExpression) != nil
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
