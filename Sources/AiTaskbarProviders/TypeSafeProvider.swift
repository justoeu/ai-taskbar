import Foundation
import AiTaskbarCore

/// TypeSafe AI (Jev), API-key heartbeat.
///
/// The only call is `GET /v1/models`: it validates the key and costs nothing.
/// The provider never calls `POST /v1/systemone` — every evaluation bills
/// input tokens and would show up in the user's own usage
/// (docs/SDD-typesafe-jev.md §3.2).
public final class TypeSafeProvider: UsageProvider {
    public let vendorId: VendorId = .typesafe
    private let credentials: EnvOrConfigCredentialReader
    private let fetcher: CachedFetch
    private let http: HTTPClient
    private let baseURL: URL

    /// The single request this provider may ever build.
    public static let modelsPath = "v1/models"

    public init(credentials: EnvOrConfigCredentialReader,
                cache: DiskCache,
                http: HTTPClient,
                baseURL: URL) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
        self.baseURL = baseURL
    }

    public convenience init(config: TypeSafeConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 300) throws {
        let cache = try DiskCache.defaultFor(.typesafe, ttl: cacheTTL)
        // `config.baseURL` is already host-validated by `TypeSafeConfig`.
        let baseURL = URL(string: config.baseURL) ?? URL(string: TypeSafeConfig.defaultBaseURL)!
        self.init(
            credentials: EnvOrConfigCredentialReader(
                envVarName: config.apiKeyEnv,
                inlineKey: config.apiKey,
                vendorName: "TypeSafe"
            ),
            cache: cache,
            http: http,
            baseURL: baseURL
        )
    }

    /// The models request, without the key. Exposed so tests can pin that the
    /// provider only ever targets `/v1/models`.
    public func modelsRequest(apiKey: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(Self.modelsPath))
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    public func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        try Task.checkCancellation()
        return try await fetcher.run(
            forceRefresh: forceRefresh,
            decode: decodeSnapshot,
            fetch: { [self] in
                let apiKey = try credentials.read()
                do {
                    return try await http.fetchPayload(modelsRequest(apiKey: apiKey))
                } catch let error {
                    throw Self.normalize(AppError.wrapping(error))
                }
            }
        )
    }

    /// TypeSafe answers a missing key with 403 and an invalid one with 401
    /// (measured 2026-09-29). Both mean "the key was refused", so both surface
    /// as 401 — the status the app already renders as a bad API key.
    static func normalize(_ error: AppError) -> AppError {
        if case .http(403, let body) = error,
           let parsed = try? SharedCoders.decoder.decode(TypeSafeErrorResponse.self, from: Data(body.utf8)),
           parsed.errorType == "authentication_error" {
            return .http(status: 401, body: body)
        }
        return error
    }

    private func decodeSnapshot(_ data: Data) throws -> VendorSnapshot {
        do {
            let parsed = try SharedCoders.decoder.decode(TypeSafeModelsResponse.self, from: data)
            return .typesafe(parsed.toSnapshot())
        } catch {
            throw AppError.schema("typesafe models decode: \(error)")
        }
    }
}
