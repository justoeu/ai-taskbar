import Foundation
import AiTaskbarCore

/// Renders the structured notices Providers emit (`VendorDisclaimer`,
/// `AppError.guidance`) in the user's language. Providers never build these
/// sentences themselves: see CLAUDE.md, "emit structure and let the localized
/// view render it".
@MainActor
public enum VendorNoticeText {
    public static func key(for disclaimer: VendorDisclaimer) -> String {
        switch disclaimer {
        case .antigravityRequired: return "gemini_antigravity_disclaimer"
        case .grokCLIRequired:     return "xai_grok_disclaimer"
        }
    }

    public static func key(for guidance: VendorGuidance) -> String {
        switch guidance {
        case .antigravityRequired:         return "guidance_antigravity_required"
        case .antigravityNotFound:         return "gemini_antigravity_not_installed"
        case .antigravityNotAuthenticated: return "gemini_antigravity_not_logged_in"
        case .antigravityUnavailable:      return "guidance_antigravity_unavailable"
        case .antigravityTimedOut:         return "guidance_antigravity_timed_out"
        case .antigravityCanceled:         return "guidance_antigravity_canceled"
        case .grokCLIRequired:             return "guidance_grok_cli_required"
        }
    }

    public static func text(for disclaimer: VendorDisclaimer) -> String {
        L10n.localizedString(key(for: disclaimer))
    }

    /// Card text for a failed fetch: localized for `.guidance`, the error's
    /// own diagnostic for everything else (unchanged behavior).
    public static func message(for error: AppError) -> String {
        if case .guidance(let guidance) = error {
            return L10n.localizedString(key(for: guidance))
        }
        return error.localizedDescription
    }

    /// Tooltip for a stale card: why the live fetch failed. Localized for a
    /// guidance failure (CQ-MAE-005: it used to show the English
    /// "guidance: …" diagnostic), the stored diagnostic for anything else,
    /// and the generic stale hint when no error was captured.
    public static func staleDetail(for error: FetchError?) -> String {
        guard let error else { return L10n.localizedString("stale_help") }
        if let guidance = error.guidance {
            return L10n.localizedString(key(for: guidance))
        }
        return error.body
    }
}
