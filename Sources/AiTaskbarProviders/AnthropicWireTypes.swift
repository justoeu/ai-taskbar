import Foundation
import AiTaskbarCore

/// Wire shapes for `GET https://api.anthropic.com/api/oauth/usage`. Fields are
/// kept Optional because the endpoint is undocumented and Anthropic has been
/// observed to add/remove fields without notice.
public struct AnthropicUsageResponse: Decodable {
    public let five_hour: AnthropicWindow?
    public let seven_day: AnthropicWindow?
    public let seven_day_opus: AnthropicWindow?
    public let extra_usage: AnthropicExtraUsage?
    /// Newer structured limits array. Model-scoped windows (e.g. "Fable") live
    /// here as `weekly_scoped` entries carrying a `scope.model.display_name` —
    /// the flat `seven_day_*` fields for those models now come back `null`.
    public let limits: [AnthropicLimit]?
    /// Earned limit resets. Sent only when asked (`?cedar_ember=1`) and
    /// filled only for the Claude Code CLI surface; see
    /// `docs/SDD-claude-limit-reset.md`.
    public let cedar_ember: AnthropicResetStatus?

    enum CodingKeys: String, CodingKey {
        case five_hour, seven_day, seven_day_opus, extra_usage, limits, cedar_ember
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        five_hour = try c.decodeIfPresent(AnthropicWindow.self, forKey: .five_hour)
        seven_day = try c.decodeIfPresent(AnthropicWindow.self, forKey: .seven_day)
        seven_day_opus = try c.decodeIfPresent(AnthropicWindow.self, forKey: .seven_day_opus)
        extra_usage = try c.decodeIfPresent(AnthropicExtraUsage.self, forKey: .extra_usage)
        limits = try c.decodeIfPresent([AnthropicLimit].self, forKey: .limits)
        // The reset block is only fetched while a window is above 90%: a
        // reshaped block must cost the reset buttons, never the usage card.
        do {
            cedar_ember = try c.decodeIfPresent(AnthropicResetStatus.self, forKey: .cedar_ember)
        } catch {
            AppLog.network.error("anthropic cedar_ember ignored: \(String(describing: error), privacy: .public)")
            cedar_ember = nil
        }
    }
}

/// The `cedar_ember` block. Allow-list: `event_props` (tier, tenure, billing
/// path) and the counters the app does not use are never decoded. A
/// malformed grant is dropped on its own, as Claude Code does, instead of
/// failing the whole usage payload.
public struct AnthropicResetStatus: Decodable {
    public let eligible: Bool?
    public let next_grant_id: String?
    public let grants: [AnthropicResetGrant]

    enum CodingKeys: String, CodingKey { case eligible, next_grant_id, grants }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eligible = try? c.decodeIfPresent(Bool.self, forKey: .eligible)
        next_grant_id = try? c.decodeIfPresent(String.self, forKey: .next_grant_id)
        let lossy = (try? c.decodeIfPresent([LossyGrant].self, forKey: .grants)) ?? []
        grants = lossy.compactMap(\.value)
    }

    private struct LossyGrant: Decodable {
        let value: AnthropicResetGrant?
        init(from decoder: Decoder) {
            do {
                value = try AnthropicResetGrant(from: decoder)
            } catch {
                value = nil
            }
        }
    }

    static let grantFields: Set<String> = ["id", "label", "resets_left", "starts_at", "ends_at", "clears",
                                           "paused", "type", "gives_back_weekly", "unavailable_reason"]

    /// The payload with `cedar_ember` reduced to the decoded allow-list
    /// (`eligible`, `next_grant_id`, and per grant `grantFields`), so the raw
    /// `event_props` (tier, tenure, billing path) is never written to the
    /// cache. A payload without the block is returned untouched.
    public static func sanitizedPayload(_ data: Data) throws -> Data {
        let value: JSONValue
        do {
            value = try SharedCoders.decoder.decode(JSONValue.self, from: data)
        } catch {
            throw AppError.schema("anthropic usage is not JSON: \(error)")
        }
        guard case .object(var root) = value, let block = root["cedar_ember"], block != .null else { return data }
        if case .object(let status) = block {
            var kept: [String: JSONValue] = [:]
            if let eligible = status["eligible"] { kept["eligible"] = eligible }
            if let next = status["next_grant_id"] { kept["next_grant_id"] = next }
            if case .array(let grants) = status["grants"] {
                kept["grants"] = .array(grants.map { grant in
                    guard case .object(let fields) = grant else { return .null }
                    return .object(fields.filter { grantFields.contains($0.key) })
                })
            }
            root["cedar_ember"] = .object(kept)
        } else {
            root["cedar_ember"] = nil
        }
        do {
            return try JSONEncoder().encode(JSONValue.object(root))
        } catch {
            throw AppError.schema("anthropic usage re-encode: \(error)")
        }
    }

    /// Grants the app may offer, server's next grant first, then by expiry.
    /// An ineligible account yields none even if it lists grants.
    public func toGrants() -> [ClaudeResetGrant] {
        guard eligible == true else { return [] }
        let mapped = grants.compactMap { $0.toGrant() }
        return mapped.enumerated().sorted { lhs, rhs in
            let lNext = lhs.element.id == next_grant_id, rNext = rhs.element.id == next_grant_id
            if lNext != rNext { return lNext }
            switch (lhs.element.endsAt, rhs.element.endsAt) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

public struct AnthropicResetGrant: Decodable {
    public let id: String
    public let label: String?
    public let resets_left: Double?
    public let starts_at: String?
    public let ends_at: String?
    public let clears: [String]?
    public let paused: Bool?
    public let type: String?
    public let gives_back_weekly: Bool?
    public let unavailable_reason: String?

    enum CodingKeys: String, CodingKey {
        case id, label, resets_left, starts_at, ends_at, clears, paused, type,
             gives_back_weekly, unavailable_reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        resets_left = c.flexibleDoubleIfPresent(forKey: .resets_left)
        starts_at = try? c.decodeIfPresent(String.self, forKey: .starts_at)
        ends_at = try? c.decodeIfPresent(String.self, forKey: .ends_at)
        clears = try? c.decodeIfPresent([String].self, forKey: .clears)
        paused = try? c.decodeIfPresent(Bool.self, forKey: .paused)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        gives_back_weekly = try? c.decodeIfPresent(Bool.self, forKey: .gives_back_weekly)
        unavailable_reason = try? c.decodeIfPresent(String.self, forKey: .unavailable_reason)
    }

    /// Claude Code refuses to claim an id outside this pattern; so do we.
    static func isValidID(_ id: String) -> Bool {
        (1...40).contains(id.count)
            && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
    }

    /// nil for a grant that can never be offered: bad id, paused, none left,
    /// or one the server marks unavailable.
    func toGrant() -> ClaudeResetGrant? {
        guard Self.isValidID(id), paused != true, unavailable_reason == nil,
              let left = resets_left.flatMap({ Int(checkedTruncating: $0) }), left > 0 else { return nil }
        let clears = clears ?? []
        let givesBack = gives_back_weekly ?? false
        return ClaudeResetGrant(
            id: id,
            label: String((label ?? "").prefix(160)),
            kind: ClaudeResetGrant.classify(type: type, clears: clears, givesBackWeekly: givesBack),
            resetsLeft: left,
            clears: clears,
            givesBackWeekly: givesBack,
            startsAt: starts_at.flatMap(ISO8601Parsing.parse),
            endsAt: ends_at.flatMap(ISO8601Parsing.parse))
    }
}

/// One entry of the `limits` array. Generic on purpose: any entry with a
/// `scope.model.display_name` is a per-model quota, so a newly-launched model
/// surfaces without a code change.
public struct AnthropicLimit: Decodable {
    public let kind: String?          // "session" | "weekly_all" | "weekly_scoped" | …
    public let group: String?         // "session" | "weekly"
    public let percent: Double?       // 0…100 (sometimes >100)
    public let severity: String?      // "normal" | "warning" | "critical"
    public let resets_at: String?     // ISO-8601
    public let is_active: Bool?
    public let scope: AnthropicLimitScope?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, resets_at, is_active, scope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        percent = c.flexibleDoubleIfPresent(forKey: .percent)
        severity = try c.decodeIfPresent(String.self, forKey: .severity)
        resets_at = try c.decodeIfPresent(String.self, forKey: .resets_at)
        is_active = try c.decodeIfPresent(Bool.self, forKey: .is_active)
        scope = try c.decodeIfPresent(AnthropicLimitScope.self, forKey: .scope)
    }
}

public struct AnthropicLimitScope: Decodable {
    public let model: AnthropicLimitModel?
}

public struct AnthropicLimitModel: Decodable {
    public let id: String?
    public let display_name: String?
}

public struct AnthropicWindow: Decodable {
    public let utilization: Double?       // 0...100 (sometimes >100)
    public let resets_at: String?         // ISO-8601
    public let used: Double?
    public let limit: Double?

    enum CodingKeys: String, CodingKey {
        case utilization, resets_at, used, limit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = c.flexibleDoubleIfPresent(forKey: .utilization)
        resets_at = try c.decodeIfPresent(String.self, forKey: .resets_at)
        used = c.flexibleDoubleIfPresent(forKey: .used)
        limit = c.flexibleDoubleIfPresent(forKey: .limit)
    }
}

/// Usage credits ("Créditos de uso"). Anthropic renamed these fields: the old
/// `enabled` / `usage_dollars` / `limit_dollars` are gone, replaced by
/// `is_enabled` / `used_credits` / `monthly_limit` plus an explicit currency
/// and minor-unit scale (`used_credits` = 55668, `decimal_places` = 2, currency
/// "BRL" → R$556.68). Amounts are minor units (divide by 10^decimal_places).
public struct AnthropicExtraUsage: Decodable {
    public let is_enabled: Bool?
    public let monthly_limit: Double?
    public let used_credits: Double?
    public let utilization: Double?
    public let currency: String?
    public let decimal_places: Int?

    enum CodingKeys: String, CodingKey {
        case is_enabled, monthly_limit, used_credits, utilization, currency, decimal_places
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        is_enabled = try c.decodeIfPresent(Bool.self, forKey: .is_enabled)
        monthly_limit = c.flexibleDoubleIfPresent(forKey: .monthly_limit)
        used_credits = c.flexibleDoubleIfPresent(forKey: .used_credits)
        utilization = c.flexibleDoubleIfPresent(forKey: .utilization)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        decimal_places = try c.decodeIfPresent(Int.self, forKey: .decimal_places)
    }
}

/// Deterministic, locale-independent money formatting for the credits detail
/// line. Kept locale-free so golden tests stay stable across machines/CI; the
/// view layer can localize later if needed.
enum AnthropicMoneyFormat {
    static func range(usedMinor: Double, limitMinor: Double,
                      currency: String?, decimalPlaces: Int) -> String {
        let sym = symbol(for: currency)
        return "\(sym)\(amount(usedMinor, dp: decimalPlaces)) / \(sym)\(amount(limitMinor, dp: decimalPlaces))"
    }

    static func amount(_ minor: Double, dp: Int) -> String {
        // Clamp to a sane range: `dp` comes off the wire, and an absurd value
        // (e.g. Int.max) would produce a `%.<huge>f` precision token that is UB
        // in the underlying vasprintf. No real currency exceeds 4 decimals.
        let places = min(max(0, dp), 6)
        let divisor = pow(10.0, Double(places))
        return String(format: "%.\(places)f", minor / divisor)
    }

    static func symbol(for currency: String?) -> String {
        switch currency?.uppercased() {
        case "BRL": return "R$"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case .some(let code) where !code.isEmpty: return "\(code) "
        default: return ""
        }
    }
}

extension AnthropicUsageResponse {
    public func toSnapshot(planLabel: String?) -> AnthropicSnapshot {
        func window(_ raw: AnthropicWindow?, label: String) -> UsageWindow? {
            guard let raw, let percent = raw.utilization else { return nil }
            var detail: String?
            if let used = raw.used, let limit = raw.limit, limit > 0 {
                detail = String(format: "%.0f / %.0f", used, limit)
            }
            return UsageWindow(
                label: label,
                utilizationPercent: percent,
                resetsAt: raw.resets_at.flatMap(ISO8601Parsing.parse),
                detail: detail
            )
        }
        // Model-scoped WEEKLY windows from the generic `limits` array (e.g.
        // "Fable"); emit them all so a new model appears without a code change.
        // Restrict to `kind == "weekly_scoped"` on purpose: (a) the plain
        // `session` / `weekly_all` entries already come through the flat
        // `five_hour` / `seven_day` fields, and (b) a hypothetical model-scoped
        // *session* limit would otherwise be mislabeled "(7d)" AND could
        // collide with a weekly one on the `id: \.label` the UI keys rows by.
        // Dedupe by label as a belt-and-braces against a scoped entry
        // duplicating a flat window (e.g. a scoped "Opus" vs `seven_day_opus`):
        // the set is seeded with the flat labels actually emitted, so the flat
        // window wins and `windows` never carries two rows with one label.
        let session = window(five_hour, label: "Session (5h)")
        let weekly = window(seven_day, label: "Weekly (7d)")
        let opus = window(seven_day_opus, label: "Opus (7d)")
        var seenScoped = Set([session, weekly, opus].compactMap { $0?.label })
        let scoped: [UsageWindow] = (limits ?? []).compactMap { limit in
            guard limit.kind == "weekly_scoped",
                  let name = limit.scope?.model?.display_name,
                  let percent = limit.percent else { return nil }
            let label = "\(name) (7d)"
            guard seenScoped.insert(label).inserted else { return nil }
            return UsageWindow(
                label: label,
                utilizationPercent: percent,
                resetsAt: limit.resets_at.flatMap(ISO8601Parsing.parse),
                detail: nil
            )
        }

        // Usage credits: percent bar + money detail (e.g. "R$556.68 / R$600.00").
        var credits: UsageWindow?
        if let ex = extra_usage, ex.is_enabled == true, let percent = ex.utilization {
            var detail: String?
            if let used = ex.used_credits, let limit = ex.monthly_limit {
                detail = AnthropicMoneyFormat.range(
                    usedMinor: used, limitMinor: limit,
                    currency: ex.currency, decimalPlaces: ex.decimal_places ?? 2)
            }
            credits = UsageWindow(label: "Usage credits",
                                  utilizationPercent: percent,
                                  resetsAt: nil,
                                  detail: detail)
        }

        return AnthropicSnapshot(
            planLabel: planLabel,
            session: session,
            weekly:  weekly,
            opus:    opus,
            scoped:  scoped,
            credits: credits,
            resetGrants: cedar_ember?.toGrants() ?? []
        )
    }
}
