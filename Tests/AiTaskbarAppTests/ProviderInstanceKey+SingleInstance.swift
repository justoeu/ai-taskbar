import AiTaskbarCore

/// Test-only shorthand: `.anthropic` for "the single instance of a vendor",
/// so pin/notification tests written before multi-account keep reading as
/// they did. Deliberately NOT in production code, where a `VendorId` must
/// never silently stand in for a specific account.
extension ProviderInstanceKey {
    static let anthropic = ProviderInstanceKey(vendor: .anthropic)
    static let openai = ProviderInstanceKey(vendor: .openai)
    static let zai = ProviderInstanceKey(vendor: .zai)
    static let openrouter = ProviderInstanceKey(vendor: .openrouter)
    static let kimi = ProviderInstanceKey(vendor: .kimi)
    static let gemini = ProviderInstanceKey(vendor: .gemini)
    static let deepseek = ProviderInstanceKey(vendor: .deepseek)
    static let xai = ProviderInstanceKey(vendor: .xai)
    static let typesafe = ProviderInstanceKey(vendor: .typesafe)
    static let meta = ProviderInstanceKey(vendor: .meta)
}
