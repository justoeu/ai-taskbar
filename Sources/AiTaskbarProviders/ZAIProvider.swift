import Foundation
import AiTaskbarCore

public final class ZAIProvider: UsageProvider {
    public let vendorId: VendorId = .zai
    private let credentials: EnvOrConfigCredentialReader
    private let fetcher: CachedFetch
    private let http: HTTPClient
    private let configTier: String?
    private static let usageURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    public init(credentials: EnvOrConfigCredentialReader,
                cache: DiskCache,
                http: HTTPClient,
                configTier: String? = nil) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
        self.configTier = configTier
    }

    public convenience init(config: ZAIConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 300) throws {
        let cache = try DiskCache.defaultFor(.zai, ttl: cacheTTL)
        self.init(
            credentials: EnvOrConfigCredentialReader(
                envVarName: config.apiKeyEnv,
                inlineKey: config.apiKey,
                vendorName: "Z.AI"
            ),
            cache: cache,
            http: http,
            configTier: config.planTier
        )
    }

    public func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        try await fetcher.run(
            forceRefresh: forceRefresh,
            decode: decodeSnapshot,
            fetch: { [self] in
                let apiKey = try credentials.read()
                var req = URLRequest(url: Self.usageURL)
                req.timeoutInterval = 10
                // **NO** "Bearer " prefix — Z.AI rejects that with 401.
                req.setValue(apiKey, forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
                return try await http.fetchPayload(req)
            }
        )
    }

    private func decodeSnapshot(_ data: Data) throws -> VendorSnapshot {
        do {
            let parsed = try SharedCoders.decoder.decode(ZAIEnvelope.self, from: data)
            return .zai(parsed.toSnapshot(configTier: configTier))
        } catch {
            throw AppError.schema("zai usage decode: \(error)")
        }
    }
}
