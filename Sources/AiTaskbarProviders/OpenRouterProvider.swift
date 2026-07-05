import Foundation
import AiTaskbarCore

public final class OpenRouterProvider: UsageProvider {
    public let vendorId: VendorId = .openrouter
    private let credentials: EnvOrConfigCredentialReader
    private let fetcher: CachedFetch
    private let http: HTTPClient
    private static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    private static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    private static let activityURL = URL(string: "https://openrouter.ai/api/v1/activity")!

    public init(credentials: EnvOrConfigCredentialReader,
                cache: DiskCache,
                http: HTTPClient) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
    }

    public convenience init(config: OpenRouterConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 300) throws {
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
                async let credits = fetchOne(url: Self.creditsURL, apiKey: apiKey,
                                              as: OpenRouterCreditsResponse.self)
                async let key = fetchOne(url: Self.keyURL, apiKey: apiKey,
                                          as: OpenRouterKeyResponse.self)
                async let activity = fetchActivity(url: Self.activityURL, apiKey: apiKey)
                let (creditsResp, keyResp, activityResp) = try await (credits, key, activity)
                try Task.checkCancellation()
                let payload = OpenRouterCachedPayload(
                    credits: creditsResp,
                    key: keyResp,
                    activity: activityResp
                )
                return try SharedCoders.encoder.encode(payload)
            }
        )
    }

    private func fetchActivity(url: URL, apiKey: String) async throws -> OpenRouterActivityResponse? {
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return try await http.sendDecoding(req, as: OpenRouterActivityResponse.self)
        } catch let error {
            let appErr = AppError.wrapping(error)
            if case .http(let code, _) = appErr, code == 403 {
                return nil
            }
            throw appErr
        }
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
            return .openrouter(payload.toSnapshot())
        } catch {
            throw AppError.schema("openrouter cached payload decode: \(error)")
        }
    }
}
