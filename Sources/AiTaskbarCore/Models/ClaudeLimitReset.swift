import Foundation

/// What a Claude limit reset gives back. Mirrors Claude Code's own
/// classification (`/limit-reset [fable|full|5-hour|weekly]`, measured in
/// CLI 2.1.322 on 2026-11-12): a grant that gives back weekly usage is a
/// Fable reset; otherwise the server's `type`, else what it clears.
public enum ClaudeResetKind: String, Sendable, Codable, CaseIterable {
    case session, weekly, fable, full

    /// The order Claude Code lists them in.
    public static let displayOrder: [ClaudeResetKind] = [.session, .weekly, .fable, .full]
}

/// One earned reset grant from the usage endpoint's `cedar_ember` block.
/// Allow-listed fields only; the block's `event_props` (tier, tenure,
/// billing path) is never decoded.
public struct ClaudeResetGrant: Sendable, Equatable, Codable {
    /// Server id, `^[a-z0-9_-]{1,40}$` (checked at decode). Sent back on claim.
    public let id: String
    /// Server text, e.g. "One full limit reset (November 2026)".
    public let label: String
    public let kind: ClaudeResetKind
    public let resetsLeft: Int
    /// Wire limit ids this grant clears (`five_hour`, `seven_day`,
    /// `seven_day_opus`, `seven_day_overage_included`, ...).
    public let clears: [String]
    public let givesBackWeekly: Bool
    public let startsAt: Date?
    public let endsAt: Date?

    public init(id: String, label: String, kind: ClaudeResetKind, resetsLeft: Int,
                clears: [String], givesBackWeekly: Bool,
                startsAt: Date? = nil, endsAt: Date? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.resetsLeft = max(0, resetsLeft)
        self.clears = clears
        self.givesBackWeekly = givesBackWeekly
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    /// Claude Code's rule: gives back weekly → Fable; an explicit type wins;
    /// otherwise only `five_hour` → session, only others → weekly, both → full.
    public static func classify(type: String?, clears: [String], givesBackWeekly: Bool) -> ClaudeResetKind {
        if givesBackWeekly { return .fable }
        if let type, let kind = ClaudeResetKind(rawValue: type), kind != .fable { return kind }
        let session = clears.contains("five_hour")
        let other = clears.contains { $0 != "five_hour" }
        if session && !other { return .session }
        if other && !session { return .weekly }
        return .full
    }

    public func isUsable(now: Date) -> Bool {
        guard resetsLeft > 0 else { return false }
        if let startsAt, startsAt > now { return false }
        if let endsAt, endsAt <= now { return false }
        return true
    }

    /// The card windows this grant would refill. `seven_day_overage_included`
    /// is the model-scoped weekly limit (Fable), drawn as a scoped row.
    func windows(in snapshot: AnthropicSnapshot) -> [UsageWindow] {
        let all = [snapshot.session, snapshot.weekly, snapshot.opus].compactMap { $0 } + snapshot.scoped
        if kind == .full && clears.isEmpty { return all }
        var out: [UsageWindow] = []
        for limit in clears {
            switch limit {
            case "five_hour": out += [snapshot.session].compactMap { $0 }
            case "seven_day": out += [snapshot.weekly].compactMap { $0 }
            case "seven_day_opus": out += [snapshot.opus].compactMap { $0 }
            case "seven_day_overage_included": out += snapshot.scoped
            default: break
            }
        }
        if givesBackWeekly, let weekly = snapshot.weekly { out.append(weekly) }
        return out
    }
}

/// A reset the card may offer: one per kind, aimed at one grant.
public struct ClaudeResetOffer: Sendable, Equatable, Identifiable {
    public let kind: ClaudeResetKind
    /// The grant a claim spends (the server's next grant when it is of this
    /// kind, else the one expiring first).
    public let grant: ClaudeResetGrant
    /// Usable resets of this kind across all grants.
    public let resetsLeft: Int
    public var id: ClaudeResetKind { kind }

    public init(kind: ClaudeResetKind, grant: ClaudeResetGrant, resetsLeft: Int) {
        self.kind = kind
        self.grant = grant
        self.resetsLeft = resetsLeft
    }
}

public extension AnthropicSnapshot {
    /// Same rule as the OpenAI reset: a usable reset exists AND a window it
    /// refills is above 90% (strictly) and not already past its reset time.
    func limitResetOffers(now: Date = Date()) -> [ClaudeResetOffer] {
        let usable = resetGrants.filter { $0.isUsable(now: now) }
        return ClaudeResetKind.displayOrder.compactMap { kind in
            let grants = usable.filter { $0.kind == kind }
            guard let target = grants.first(where: { grant in
                grant.windows(in: self).contains {
                    $0.utilizationPercent.isFinite && $0.utilizationPercent > 90 && !$0.isAwaitingReset(now: now)
                }
            }) else { return nil }
            return ClaudeResetOffer(kind: kind, grant: target,
                                    resetsLeft: grants.reduce(0) { $0 + $1.resetsLeft })
        }
    }

    /// True when any window is above 90%: the only time a reset can be
    /// offered, so the only time the provider asks for the reset status.
    var hasWindowAboveResetThreshold: Bool {
        ([session, weekly, opus].compactMap { $0 } + scoped).contains {
            $0.utilizationPercent.isFinite && $0.utilizationPercent > 90
        }
    }
}
