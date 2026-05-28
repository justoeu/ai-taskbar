import Foundation
import AiTaskbarCore

public final class OpenRouterProvider: UsageProvider {
    public let vendorId: VendorId = .openrouter
    private let credentials: EnvOrConfigCredentialReader
    private let fetcher: CachedFetch
    private let http: HTTPClient
    private static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    private static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!

    public init(credentials: EnvOrConfigCredentialReader,
                cache: DiskCache,
                http: HTTPClient) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
    }

    public convenience init(config: OpenRouterConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 150) throws {
        let cache = try DiskCache.defaultFor(.openrouter, ttl: cacheTTL)
        self.init(
            credentials: EnvOrConfigCredentialReader(
                envVarName: config.apiKeyEnv,
                inlineKey: config.apiKey,
                vendorName: "OpenRouter"
            ),
            cache: cache,
            http: http
        )
    }

    public func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        try await fetcher.run(
            forceRefresh: forceRefresh,
            decode: decodeSnapshot,
            fetch: { [self] in
                let apiKey = try credentials.read()
                // Parallel fetch of both documented endpoints.
                async let credits = fetchOne(url: Self.creditsURL, apiKey: apiKey,
                                              as: OpenRouterCreditsResponse.self)
                async let key = fetchOne(url: Self.keyURL, apiKey: apiKey,
                                          as: OpenRouterKeyResponse.self)
                let (creditsResp, keyResp) = try await (credits, key)
                try Task.checkCancellation()
                let payload = OpenRouterCachedPayload(credits: creditsResp, key: keyResp)
                return try SharedCoders.encoder.encode(payload)
            }
        )
    }

    private func fetchOne<T: Decodable>(url: URL, apiKey: String,
                                         as: T.Type) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return try await http.sendDecoding(req, as: T.self)
    }

    private func decodeSnapshot(_ data: Data) throws -> VendorSnapshot {
        do {
            let payload = try SharedCoders.decoder.decode(OpenRouterCachedPayload.self, from: data)
            let snap = OpenRouterCombined(credits: payload.credits, key: payload.key).toSnapshot()
            return .openrouter(snap)
        } catch {
            throw AppError.schema("openrouter cached payload decode: \(error)")
        }
    }
}
