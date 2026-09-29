import Foundation

/// Informational notice a vendor card carries, as STRUCTURE rather than prose.
///
/// Providers never build a user-facing sentence (CLAUDE.md: "emit structure
/// and let the localized view render it"). The App maps each case to a key in
/// `Localizable.strings`. Gemini and xAI once stored a Portuguese sentence
/// here, so every en/es user read Portuguese on those two cards.
public enum VendorDisclaimer: String, Sendable, Equatable, Codable, CaseIterable {
    /// Gemini quota monitoring needs the Antigravity CLI (`agy`) installed and signed in.
    case antigravityRequired
    /// Grok quota monitoring needs the Grok CLI installed and signed in.
    case grokCLIRequired
}

/// Recoverable setup states a provider reports through `AppError.guidance`.
///
/// Each case is a situation the user fixes by installing or signing in to a
/// CLI, not a bug. The App renders it via L10n. `diagnostic` is the English
/// text for logs and the persisted `.last_error`, like every other
/// `AppError` message; it is not what the card shows.
public enum VendorGuidance: String, Sendable, Equatable, Codable, CaseIterable {
    /// `prefer_antigravity` is on, `agy` is missing and no API key is set.
    case antigravityRequired
    /// The `agy` executable was not found at any known location.
    case antigravityNotFound
    /// `agy` reported that the user is not signed in.
    case antigravityNotAuthenticated
    /// The Antigravity backend answered UNAVAILABLE.
    case antigravityUnavailable
    /// `agy` did not answer within the executor's time budget.
    case antigravityTimedOut
    /// `agy` reported `context canceled`.
    case antigravityCanceled
    /// `prefer_grok_cli` is on, Grok CLI auth is missing and no team_id is set.
    case grokCLIRequired

    /// HTTP status the situation is equivalent to, so the 401 re-login banner
    /// and the transient/back-off logic treat it as they treated the old
    /// `AppError.http` form. nil = not an HTTP-shaped condition.
    public var httpStatus: Int? {
        switch self {
        case .antigravityNotAuthenticated: return 401
        case .antigravityUnavailable:      return 503
        default:                           return nil
        }
    }

    /// English diagnostic for logs and `.last_error`. Not rendered by the card.
    public var diagnostic: String {
        switch self {
        case .antigravityRequired:
            return "Antigravity is required: install 'agy' or set GEMINI_API_KEY"
        case .antigravityNotFound:
            return "the 'agy' executable was not found"
        case .antigravityNotAuthenticated:
            return "Antigravity is not authenticated; run 'agy' to sign in"
        case .antigravityUnavailable:
            return "Antigravity service temporarily unavailable"
        case .antigravityTimedOut:
            return "timed out waiting for agy"
        case .antigravityCanceled:
            return "agy: context canceled"
        case .grokCLIRequired:
            return "Grok CLI is required (grok login), or set the xAI management key and team_id"
        }
    }
}
