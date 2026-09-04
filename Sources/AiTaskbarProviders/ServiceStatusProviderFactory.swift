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

    /// Builds network-backed providers only for supported IDs in the received
    /// order. Link-only and not-yet-integrated sources remain the app store's
    /// explicit `unknown` rows and perform no request here.
    public static func makeProviders(
        for vendorIds: [VendorId],
        http: HTTPClient = .init(),
        cacheTTL: TimeInterval = 300
    ) throws -> [any ServiceStatusProvider] {
        try vendorIds.compactMap { vendorId in
            guard let descriptor = descriptor(for: vendorId) else { return nil }
            return try CachedServiceStatusProvider(
                source: StatuspageSource(descriptor: descriptor),
                http: http,
                cacheTTL: cacheTTL
            ) as any ServiceStatusProvider
        }
    }
}
