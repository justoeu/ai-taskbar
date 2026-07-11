import Foundation
import AiTaskbarCore

/// xAI Management API provider.
///
/// Requires a **management key** (console.x.ai → Settings → Management Keys)
/// and a `team_id`. Inference API keys on `api.x.ai` cannot read billing.
///
/// Fetches in parallel:
/// - prepaid credit balance
/// - current postpaid invoice preview (spend + spending limit)
public final class XAIProvider: UsageProvider {
    public let vendorId: VendorId = .xai
    private let credentials: EnvOrConfigCredentialReader
    private let fetcher: CachedFetch
    private let http: HTTPClient
    private let baseURL: URL
    private let teamId: String

    public init(credentials: EnvOrConfigCredentialReader,
                cache: DiskCache,
                http: HTTPClient,
                baseURL: URL,
                teamId: String) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
        self.baseURL = baseURL
        self.teamId = teamId
    }

    public convenience init(config: XAIConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 300) throws {
        let cache = try DiskCache.defaultFor(.xai, ttl: cacheTTL)
        let baseURL = URL(string: config.baseURL) ?? URL(string: XAIConfig.defaultBaseURL)!
        self.init(
            credentials: EnvOrConfigCredentialReader(
                envVarName: config.apiKeyEnv,
                inlineKey: config.apiKey,
                vendorName: "xAI"
            ),
            cache: cache,
            http: http,
            baseURL: baseURL,
            teamId: config.teamId
        )
    }

    public func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        try await fetcher.run(
            forceRefresh: forceRefresh,
            decode: decodeSnapshot,
            fetch: { [self] in
                try Task.checkCancellation()
                let tid = teamId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tid.isEmpty else {
                    throw AppError.credentials("xAI team_id is required — copy it from console.x.ai → Team settings")
                }
                let apiKey = try credentials.read()
                try Task.checkCancellation()

                let prepaidURL = baseURL
                    .appendingPathComponent("v1/billing/teams")
                    .appendingPathComponent(tid)
                    .appendingPathComponent("prepaid/balance")
                let previewURL = baseURL
                    .appendingPathComponent("v1/billing/teams")
                    .appendingPathComponent(tid)
                    .appendingPathComponent("postpaid/invoice/preview")

                async let prepaid = fetchOne(url: prepaidURL, apiKey: apiKey,
                                             as: XAIPrepaidBalanceResponse.self)
                async let preview = fetchOne(url: previewURL, apiKey: apiKey,
                                             as: XAIInvoicePreviewResponse.self)
                let (prepaidResp, previewResp) = try await (prepaid, preview)
                try Task.checkCancellation()
                let payload = XAICachedPayload(prepaid: prepaidResp, preview: previewResp)
                return try SharedCoders.encoder.encode(payload)
            }
        )
    }

    private func fetchOne<T: Decodable>(url: URL, apiKey: String,
                                         as: T.Type) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await http.sendDecoding(req, as: T.self)
    }

    private func decodeSnapshot(_ data: Data) throws -> VendorSnapshot {
        do {
            let payload = try SharedCoders.decoder.decode(XAICachedPayload.self, from: data)
            return .xai(payload.toSnapshot())
        } catch {
            throw AppError.schema("xai cached payload decode: \(error)")
        }
    }
}
