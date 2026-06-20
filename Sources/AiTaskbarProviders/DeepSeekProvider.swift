import Foundation
import AiTaskbarCore

public final class DeepSeekProvider: UsageProvider {
    public let vendorId: VendorId = .deepseek
    private let credentials: EnvOrConfigCredentialReader
    private let fetcher: CachedFetch
    private let http: HTTPClient
    private let baseURL: URL

    public init(credentials: EnvOrConfigCredentialReader,
                cache: DiskCache,
                http: HTTPClient,
                baseURL: URL) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
        self.baseURL = baseURL
    }

    public convenience init(config: DeepSeekConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 300) throws {
        let cache = try DiskCache.defaultFor(.deepseek, ttl: cacheTTL)
        let baseURL = URL(string: config.baseURL) ?? URL(string: "https://api.deepseek.com")!
        self.init(
            credentials: EnvOrConfigCredentialReader(
                envVarName: config.apiKeyEnv,
                inlineKey: config.apiKey,
                vendorName: "DeepSeek"
            ),
            cache: cache,
            http: http,
            baseURL: baseURL
        )
    }

    public func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        try await fetcher.run(
            forceRefresh: forceRefresh,
            decode: decodeSnapshot,
            fetch: { [self] in
                let apiKey = try credentials.read()
                var req = URLRequest(url: baseURL.appendingPathComponent("user/balance"))
                req.timeoutInterval = 10
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                return try await http.fetchPayload(req)
            }
        )
    }

    private func decodeSnapshot(_ data: Data) throws -> VendorSnapshot {
        do {
            let parsed = try SharedCoders.decoder.decode(DeepSeekBalanceResponse.self, from: data)
            return .deepseek(parsed.toSnapshot())
        } catch {
            throw AppError.schema("deepseek balance decode: \(error)")
        }
    }
}
