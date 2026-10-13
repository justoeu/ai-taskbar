import Foundation
import AiTaskbarCore

/// Meta (Muse) subscription quota.
///
/// The only request this provider may ever build is
/// `POST https://api.meta.ai/muse-code/key` with the Muse CLI's
/// device-code login token: it reads the subscription windows and costs no
/// inference. The minted key in the response is discarded by decode
/// allow-list (`MetaWireTypes`), and the cache holds the interpreted
/// snapshot only — never the token, the minted key, or the raw body
/// (`docs/SDD-meta-muse.md` §7–§8).
public final class MetaProvider: UsageProvider, @unchecked Sendable {
    public let vendorId: VendorId = .meta
    private let credentials: any MetaCredentialReading
    private let fetcher: CachedFetch
    private let http: HTTPClient

    /// The single endpoint this provider may ever target.
    public static let mintURL = URL(string: "https://api.meta.ai/muse-code/key")!

    public init(credentials: any MetaCredentialReading,
                cache: DiskCache,
                http: HTTPClient) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
    }

    public convenience init(config: MetaConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 300) throws {
        let cache = try DiskCache.defaultFor(.meta, ttl: cacheTTL)
        self.init(credentials: MetaCredentialReader(config: config),
                  cache: cache, http: http)
    }

    /// The mint request. Exposed so tests can pin its shape.
    public func mintRequest(token: String) -> URLRequest {
        var req = URLRequest(url: Self.mintURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.httpBody = Data("{}".utf8)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("1.0.0", forHTTPHeaderField: "x-api-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    public func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        try Task.checkCancellation()
        return try await fetcher.run(
            forceRefresh: forceRefresh,
            decode: decodeSnapshot,
            fetch: { [self] in
                let token: String
                switch credentials.resolve() {
                case .token(let value):
                    token = value
                case .missing:
                    // Quiet setup state, not a noisy error (SDD §7.3/§8):
                    // guidance renders localized and (401-shaped) arms the
                    // re-login affordance.
                    throw AppError.guidance(.museLoginRequired)
                case .keychainBlocked:
                    // Credentials shape (not guidance) so the card shows
                    // the Authorize affordance: `isKeychainACLBlocked`
                    // keys on the OSStatus name, like Anthropic's reader.
                    throw AppError.credentials(
                        "Muse keychain read denied (errSecInteractionNotAllowed)")
                case .unavailable(let detail):
                    throw AppError.credentials("Muse login unavailable: \(detail)")
                }
                try Task.checkCancellation()
                // No redirects (SDD §8): a 3xx is surfaced as-is and reads
                // as unavailable through the status check below.
                let (data, response) = try await http.sendBounded(
                    mintRequest(token: token),
                    maximumResponseBytes: HTTPClient.defaultMaximumResponseBytes,
                    allowRedirect: { _ in false })
                guard (200..<300).contains(response.statusCode) else {
                    let body = String(data: data.prefix(1024), encoding: .utf8) ?? ""
                    throw AppError.http(status: response.statusCode, body: body)
                }
                try Task.checkCancellation()
                let snapshot: MetaSnapshot
                do {
                    snapshot = try SharedCoders.decoder
                        .decode(MetaMintResponse.self, from: data).toSnapshot()
                } catch let error as AppError {
                    throw error
                } catch {
                    throw AppError.schema("meta mint decode: \(error)")
                }
                try Task.checkCancellation()
                // Cache the interpreted snapshot only (TypeSafe precedent):
                // the raw body carries a minted key and payment metadata.
                return try SharedCoders.encoder.encode(snapshot)
            }
        )
    }

    /// Invoked only from the explicit Authorize button. Grants this
    /// signing identity durable access to the CLI's Keychain item, then
    /// the authorizer verifies a silent read. Cancel returns false.
    @discardableResult
    public func authorizeCredentialsInteractively() throws -> Bool {
        try credentials.authorizePersistently()
    }

    private func decodeSnapshot(_ data: Data) throws -> VendorSnapshot {
        do {
            return .meta(try SharedCoders.decoder.decode(MetaSnapshot.self, from: data))
        } catch {
            throw AppError.schema("meta snapshot decode: \(error)")
        }
    }
}
