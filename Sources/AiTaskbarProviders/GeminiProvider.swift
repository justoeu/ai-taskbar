import Foundation
import AiTaskbarCore

/// Google Gemini (Generative Language API) provider.
///
/// The public `generativelanguage.googleapis.com` host does not expose a
/// quota/billing REST endpoint — billing is managed in the Google Cloud
/// console and not surfaced via API. As a substitute, this provider hits
/// `GET /models` which is the only stable, key-authenticated endpoint. It
/// acts as a heartbeat (validates the API key) and surfaces the model count
/// as a flat "API Key" status row.
public final class GeminiProvider: UsageProvider {
    public let vendorId: VendorId = .gemini
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

    public convenience init(config: GeminiConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 300) throws {
        let cache = try DiskCache.defaultFor(.gemini, ttl: cacheTTL)
        // GeminiConfig.init(from:) already normalizes user input to the
        // default on parse failure, but we belt-and-suspenders here:
        // throw instead of force-unwrapping if both URL constructions
        // somehow fail. AppEnvironment catches the throw and disables only
        // the Gemini provider instead of crashing the whole menu-bar app.
        guard let baseURL = URL(string: config.baseURL)
                          ?? URL(string: GeminiConfig.defaultBaseURL) else {
            throw AppError.io(
                "GeminiConfig.baseURL '\(config.baseURL)' is unparseable and the built-in default also failed")
        }
        self.init(
            credentials: EnvOrConfigCredentialReader(
                envVarName: config.apiKeyEnv,
                inlineKey: config.apiKey,
                vendorName: "Gemini (Google AI)"
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
                var req = URLRequest(url: baseURL.appendingPathComponent("models"))
                req.timeoutInterval = 10
                // Header form keeps the key out of URL/query logs. The query
                // form (`?key=...`) is also accepted by Google but more
                // exposed. Always prefer the header.
                req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                return try await http.fetchPayload(req)
            }
        )
    }

    private func decodeSnapshot(_ data: Data) throws -> VendorSnapshot {
        let parsed: GeminiModelsResponse
        do {
            parsed = try SharedCoders.decoder.decode(GeminiModelsResponse.self, from: data)
        } catch {
            throw AppError.schema("gemini models decode: \(error)")
        }
        // `models` Optional becomes nil when the field is missing OR null
        // — i.e. exactly the shape a future Google v1beta rename would
        // produce (e.g. `models` → `availableModels`). Routing this
        // through `AppError.schema` instead of toSnapshot's UX branch
        // makes CachedFetch mark the vendor failed, the UI render an
        // error tint, and the regression visible rather than masquerading
        // as a healthy "no models visible" green row forever. Empty list
        // (`{"models":[]}`) is a legitimate vendor state and still flows
        // through `toSnapshot()` as a happy .ok.
        guard parsed.models != nil else {
            throw AppError.schema(
                "gemini models: response missing `models` field — base_url may be wrong or the API has changed")
        }
        return .gemini(parsed.toSnapshot())
    }
}
