import Foundation
import AiTaskbarCore

/// xAI Management API and Grok CLI provider.
///
/// Dual mode:
/// 1. Grok CLI mode (default): reads `~/.grok/auth.json` and hits `cli-chat-proxy.grok.com/v1`
///    for real-time weekly quota usage % and subscription tier ("SuperGrok Heavy").
/// 2. Management API mode: requires a management key and team_id for prepaid/postpaid balances.
public final class XAIProvider: UsageProvider {
    public let vendorId: VendorId = .xai
    public var credentialFileURL: URL? {
        if preferGrokCLI {
            return grokAuthReader.path
        }
        return nil
    }

    private let credentials: EnvOrConfigCredentialReader
    private let grokAuthReader: GrokAuthReader
    private let fetcher: CachedFetch
    private let http: HTTPClient
    private let baseURL: URL
    private let grokBaseURL: URL
    private let teamId: String
    private let preferGrokCLI: Bool

    public init(credentials: EnvOrConfigCredentialReader,
                grokAuthReader: GrokAuthReader = .init(),
                cache: DiskCache,
                http: HTTPClient,
                baseURL: URL,
                grokBaseURL: URL = URL(string: XAIConfig.defaultGrokBaseURL)!,
                teamId: String,
                preferGrokCLI: Bool = false) {
        self.credentials = credentials
        self.grokAuthReader = grokAuthReader
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
        self.baseURL = baseURL
        self.grokBaseURL = grokBaseURL
        self.teamId = teamId
        self.preferGrokCLI = preferGrokCLI
    }

    public convenience init(config: XAIConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 300) throws {
        let cache = try DiskCache.defaultFor(.xai, ttl: cacheTTL)
        let baseURL = URL(string: config.baseURL) ?? URL(string: XAIConfig.defaultBaseURL)!
        let grokBaseURL = URL(string: config.grokBaseURL) ?? URL(string: XAIConfig.defaultGrokBaseURL)!
        self.init(
            credentials: EnvOrConfigCredentialReader(
                envVarName: config.apiKeyEnv,
                inlineKey: config.apiKey,
                vendorName: "xAI"
            ),
            grokAuthReader: GrokAuthReader(path: config.grokAuthURL),
            cache: cache,
            http: http,
            baseURL: baseURL,
            grokBaseURL: grokBaseURL,
            teamId: config.teamId,
            preferGrokCLI: config.preferGrokCLI
        )
    }

    public func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        try await fetcher.run(
            forceRefresh: forceRefresh,
            decode: decodeSnapshot,
            fetch: { [self] in
                try Task.checkCancellation()

                // 1. Grok CLI mode
                if preferGrokCLI && FileManager.default.fileExists(atPath: grokAuthReader.path.path) {
                    do {
                        let auth = try grokAuthReader.read()
                        try Task.checkCancellation()

                        let billingBase = grokBaseURL.appendingPathComponent("v1/billing")
                        var comp = URLComponents(url: billingBase, resolvingAgainstBaseURL: true)
                        comp?.queryItems = [URLQueryItem(name: "format", value: "credits")]
                        guard let billingURL = comp?.url else {
                            throw AppError.io("Failed to construct Grok billing URL")
                        }
                        let settingsURL = grokBaseURL.appendingPathComponent("v1/settings")

                        async let billing = fetchOne(url: billingURL, apiKey: auth.key, as: GrokBillingResponse.self)
                        async let settings = fetchOne(url: settingsURL, apiKey: auth.key, as: GrokSettingsResponse.self)

                        let billingResp = try await billing
                        guard let bConfig = billingResp.config,
                              bConfig.creditUsagePercent != nil ||
                              bConfig.currentPeriod != nil ||
                              bConfig.prepaidBalance != nil else {
                            throw AppError.schema("Response does not contain valid Grok billing config")
                        }
                        let settingsResp = try? await settings
                        try Task.checkCancellation()

                        let payload = XAICachedPayload(grokBilling: billingResp, grokSettings: settingsResp)
                        return try SharedCoders.encoder.encode(payload)
                    } catch {
                        let tid = teamId.trimmingCharacters(in: .whitespacesAndNewlines)
                        if tid.isEmpty {
                            throw error
                        }
                        AppLog.lifecycle.warning("Grok CLI fetch failed, falling back to xAI management API: \(error)")
                    }
                }

                // 2. xAI Management API fallback
                let tid = teamId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tid.isEmpty else {
                    if preferGrokCLI {
                        throw AppError.credentials(
                            "Para monitorar o Grok, é necessário ter o Grok CLI instalado e autenticado (`grok login`), ou configure a Management Key e Team ID da xAI em console.x.ai."
                        )
                    }
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
