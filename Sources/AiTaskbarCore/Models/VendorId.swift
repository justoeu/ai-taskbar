import Foundation

public enum VendorId: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic
    case openai
    case zai
    case openrouter
    case kimi
    case gemini
    case deepseek
    case xai

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic:  return "Claude"
        case .openai:     return "Codex / ChatGPT"
        case .zai:        return "Z.AI (GLM)"
        case .openrouter: return "OpenRouter"
        case .kimi:       return "Kimi (Moonshot)"
        case .gemini:     return "Gemini (Google AI)"
        case .deepseek:   return "DeepSeek"
        case .xai:        return "xAI (Grok)"
        }
    }

    /// Official dashboard URL for billing/usage. Opens via NSWorkspace when
    /// the user clicks on the section header.
    public var dashboardURL: URL? {
        switch self {
        case .anthropic:  return URL(string: "https://claude.ai/settings/usage")
        case .openai:     return URL(string: "https://platform.openai.com/usage")
        case .openrouter: return URL(string: "https://openrouter.ai/activity")
        case .zai:        return URL(string: "https://z.ai/manage-apikey/apikey-list")
        case .kimi:       return URL(string: "https://platform.kimi.ai/console/info/account")
        case .gemini:     return URL(string: "https://aistudio.google.com/apikey")
        case .deepseek:   return URL(string: "https://platform.deepseek.com/usage")
        case .xai:        return URL(string: "https://console.x.ai/team/default/usage")
        }
    }

    /// Shell command the user can run to re-authenticate when the vendor's
    /// token is rejected with a 401. Returns nil for API-key vendors (a 401
    /// there means the key is wrong — the fix is editing config, not a CLI
    /// login). The per-vendor UI surfaces this as a "Re-login" button that
    /// runs the command in a fresh Terminal window.
    public var reloginCommand: String? {
        switch self {
        case .anthropic:  return "claude auth login"
        case .openai:     return "codex login"
        default:          return nil
        }
    }
}
