import Foundation

public enum VendorId: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic
    case openai
    case zai
    case openrouter
    case kimi

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic:  return "Claude"
        case .openai:     return "Codex / ChatGPT"
        case .zai:        return "Z.AI (GLM)"
        case .openrouter: return "OpenRouter"
        case .kimi:       return "Kimi (Moonshot)"
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
        }
    }
}
