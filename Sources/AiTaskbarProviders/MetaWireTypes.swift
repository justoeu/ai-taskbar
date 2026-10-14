import Foundation
import AiTaskbarCore

/// Subset of `POST https://api.meta.ai/muse-code/key` decoded by allow-list
/// (`docs/SDD-meta-muse.md` §8). The response also carries a minted
/// inference key and payment metadata: those fields are NOT decoded, so
/// they cannot be logged, cached, or shown by accident.
public struct MetaMintResponse: Decodable, Sendable, Equatable {
    public let isSubsActive: Bool?
    public let requirePayment: Bool?
    public let subsTierName: String?
    /// Optional all the way down at decode time: an active subscription
    /// with an idle session window omits `subs_usage` entirely, which is a
    /// valid reading, not drift. Drift is a present-but-malformed object,
    /// and `toSnapshot()` rejects that.
    public let subsUsage: SubsUsage?

    public struct SubsUsage: Decodable, Sendable, Equatable {
        public let window: Window?
        public let weekly: Window?
    }

    public struct Window: Decodable, Sendable, Equatable {
        public let usedPercent: Double?
        /// Unix seconds on the wire.
        public let resetsAt: Double?
        /// Only the session window carries a duration.
        public let windowDurationMins: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetsAt = "resets_at"
            case windowDurationMins = "window_duration_mins"
        }
    }

    enum CodingKeys: String, CodingKey {
        case isSubsActive = "is_subs_active"
        case requirePayment = "require_payment"
        case subsTierName = "subs_tier_name"
        case subsUsage = "subs_usage"
    }

    /// Upper bound accepted for `resets_at` (year 4000): outside it the
    /// date is dropped but the percentage is kept.
    static let maxResetsAtSeconds: Double = 64_092_211_200

    public func toSnapshot() throws -> MetaSnapshot {
        // `is_subs_active` is the one field every real mint response
        // carries; without it the body is not a mint response at all
        // (renamed field, maintenance JSON) and must read as schema
        // drift, never as a fabricated fresh "pay-as-you-go".
        guard let isSubsActive else {
            throw AppError.schema("meta mint response missing is_subs_active")
        }
        let state: MetaSubscriptionState
        if requirePayment == true {
            state = .billingIncomplete
        } else if isSubsActive {
            state = .active
        } else {
            state = .payAsYouGo
        }

        guard let subsUsage else {
            return MetaSnapshot(planLabel: subsTierName, subscription: state)
        }
        // Windows are independent: a response carrying only one of them
        // keeps that one. A present window without a usable percent is
        // still drift, not a window to invent.
        var session: UsageWindow?
        if let window = subsUsage.window {
            guard let parsed = Self.sessionWindow(window) else {
                throw AppError.schema("meta subs_usage.window malformed")
            }
            session = parsed
        }
        var weeklyWindow: UsageWindow?
        if let weekly = subsUsage.weekly {
            guard let parsed = Self.usageWindow(label: "Weekly (7d)", from: weekly) else {
                throw AppError.schema("meta subs_usage.weekly malformed")
            }
            weeklyWindow = parsed
        }
        return MetaSnapshot(planLabel: subsTierName, subscription: state,
                            session: session, weekly: weeklyWindow)
    }

    private static func sessionWindow(_ window: Window) -> UsageWindow? {
        // Duration only refines the label; an absent/invalid one must not
        // discard an otherwise valid window.
        let label: String
        if let minsRaw = window.windowDurationMins,
           let mins = Int(checkedTruncating: minsRaw), mins > 0 {
            label = mins % 60 == 0 ? "Session (\(mins / 60)h)" : "Session (\(mins)m)"
        } else {
            label = "Session"
        }
        return usageWindow(label: label, from: window)
    }

    private static func usageWindow(label: String, from window: Window) -> UsageWindow? {
        guard let percent = window.usedPercent, percent.isFinite else { return nil }
        let reset: Date?
        if let seconds = window.resetsAt, seconds > 0, seconds <= maxResetsAtSeconds {
            reset = Date(timeIntervalSince1970: seconds)
        } else {
            reset = nil
        }
        return UsageWindow(label: label,
                           utilizationPercent: min(100, max(0, percent)),
                           resetsAt: reset)
    }
}
