import Foundation
import AiTaskbarCore

/// TypeSafe AI (Jev): API-key heartbeat plus, when the user signed in to the
/// console in-app, billing and token usage from that session.
///
/// The only API call is `GET /v1/models`: it validates the key and costs
/// nothing. The provider never calls `POST /v1/systemone` — every evaluation
/// bills input tokens and would show up in the user's own usage
/// (docs/SDD-typesafe-jev.md §3.2). Console reads go through
/// `TypeSafeConsoleClient` (§16); their failure never fails the card.
public final class TypeSafeProvider: UsageProvider, @unchecked Sendable {
    public let vendorId: VendorId = .typesafe
    private let credentials: EnvOrConfigCredentialReader
    private let fetcher: CachedFetch
    private let http: HTTPClient
    private let baseURL: URL
    private let sessionStore: TypeSafeSessionStore
    private let console: TypeSafeConsoleClient
    private let now: @Sendable () -> Date
    /// Defines "today" for the usage rows: the user's own calendar day.
    private let calendar: Calendar
    /// Last good console data, reused (marked unavailable) when a console read
    /// fails transiently. In memory only, guarded by `lock`.
    private let lock = NSLock()
    private var lastConsole: (billing: TypeSafeBilling?, usage: TypeSafeUsage?)?

    /// The single request this provider may ever build.
    public static let modelsPath = "v1/models"

    public init(credentials: EnvOrConfigCredentialReader,
                cache: DiskCache,
                http: HTTPClient,
                baseURL: URL,
                sessionStore: TypeSafeSessionStore = TypeSafeSessionStore(),
                console: TypeSafeConsoleClient? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
        self.baseURL = baseURL
        self.sessionStore = sessionStore
        self.console = console ?? TypeSafeConsoleClient(http: http, now: now)
        self.now = now
        self.calendar = calendar
    }

    public convenience init(config: TypeSafeConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 300,
                            sessionStore: TypeSafeSessionStore = TypeSafeSessionStore()) throws {
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
            baseURL: baseURL,
            sessionStore: sessionStore
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
                let modelsData: Data
                do {
                    modelsData = try await http.fetchPayload(modelsRequest(apiKey: apiKey))
                } catch let error {
                    throw Self.normalize(AppError.wrapping(error))
                }
                try Task.checkCancellation()
                let models: TypeSafeSnapshot
                do {
                    models = try SharedCoders.decoder.decode(TypeSafeModelsResponse.self, from: modelsData).toSnapshot()
                } catch {
                    throw AppError.schema("typesafe models decode: \(error)")
                }
                let snapshot = await withConsole(models)
                try Task.checkCancellation()
                // The cache holds the interpreted snapshot only — never the
                // cookie, and no console field beyond the allowed numbers.
                return try SharedCoders.encoder.encode(snapshot)
            }
        )
    }

    /// Adds the console part. Never throws: a console problem changes
    /// `console` state, while the key/models part keeps working.
    func withConsole(_ models: TypeSafeSnapshot) async -> TypeSafeSnapshot {
        guard let session = sessionStore.current else {
            setLastConsole(nil)
            return models.with(billing: nil, usage: nil, console: .notConnected)
        }
        if session.isExpired(now: now()) {
            setLastConsole(nil)
            return models.with(billing: nil, usage: nil, console: .expired)
        }
        do {
            async let billingRead = console.fetchBilling(cookie: session.cookieHeader)
            async let usageRead = console.fetchUsage(cookie: session.cookieHeader, calendar: calendar)
            let (billing, usage) = try await (billingRead, usageRead)
            setLastConsole((billing, usage))
            return models.with(billing: billing, usage: usage, console: .connected(expiresAt: session.expiresAt))
        } catch TypeSafeConsoleError.sessionExpired {
            setLastConsole(nil)
            return models.with(billing: nil, usage: nil, console: .expired)
        } catch {
            if !(error is CancellationError) {
                AppLog.lifecycle.warning("typesafe console unavailable: \(String(describing: error), privacy: .public)")
            }
            let last = getLastConsole()
            return models.with(billing: last?.billing, usage: last?.usage, console: .unavailable(since: now()))
        }
    }

    private func setLastConsole(_ v: (billing: TypeSafeBilling?, usage: TypeSafeUsage?)?) {
        lock.lock(); lastConsole = v; lock.unlock()
    }

    private func getLastConsole() -> (billing: TypeSafeBilling?, usage: TypeSafeUsage?)? {
        lock.lock(); defer { lock.unlock() }
        return lastConsole
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
            return .typesafe(try SharedCoders.decoder.decode(TypeSafeSnapshot.self, from: data))
        } catch {
            throw AppError.schema("typesafe snapshot decode: \(error)")
        }
    }
}
