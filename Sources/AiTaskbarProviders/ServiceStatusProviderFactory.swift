import Foundation
import AiTaskbarCore

public enum ServiceStatusProviderFactory {
    public static func descriptor(for vendorId: VendorId) -> StatuspageDescriptor? {
        switch vendorId {
        case .anthropic: return .anthropic
        case .openai: return .openAI
        case .kimi: return .kimi
        case .zai, .openrouter, .gemini, .deepseek, .xai: return nil
        }
    }

    public static func rssDescriptor(for vendorId: VendorId) -> RSSStatusDescriptor? {
        switch vendorId {
        case .openrouter: return .openRouter
        case .xai: return .xAI
        case .anthropic, .openai, .zai, .kimi, .gemini, .deepseek: return nil
        }
    }

    /// Builds network-backed providers only for supported IDs in the received
    /// order. Link-only and not-yet-integrated sources remain the app store's
    /// explicit `unknown` rows and perform no request here.
    public static func makeProviders(
        for vendorIds: [VendorId],
        http: HTTPClient = .init(),
        cacheTTL: TimeInterval = 300
    ) throws -> [any ServiceStatusProvider] {
        try vendorIds.compactMap { vendorId -> (any ServiceStatusProvider)? in
            if let descriptor = descriptor(for: vendorId) {
                return try CachedServiceStatusProvider(
                    source: StatuspageSource(descriptor: descriptor),
                    http: http,
                    cacheTTL: cacheTTL
                ) as any ServiceStatusProvider
            }
            if vendorId == .deepseek {
                return try CachedServiceStatusProvider(
                    source: DeepSeekStatusSource(),
                    http: http,
                    cacheTTL: cacheTTL
                ) as any ServiceStatusProvider
            }
            if let descriptor = rssDescriptor(for: vendorId) {
                return try CachedServiceStatusProvider(
                    source: RSSStatusSource(descriptor: descriptor),
                    http: http,
                    cacheTTL: cacheTTL
                ) as any ServiceStatusProvider
            }
            return nil
        }
    }
}
