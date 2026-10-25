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
    /// Last live weekly reading, carried while the mint omits `subs_usage`.
    /// nil disables the carry (the idle note renders instead).
    private let weeklyMemory: LastSeenWindowStore?
    private let clock: @Sendable () -> Date

    /// The single endpoint this provider may ever target.
    public static let mintURL = URL(string: "https://api.meta.ai/muse-code/key")!

    public init(credentials: any MetaCredentialReading,
                cache: DiskCache,
                http: HTTPClient,
                weeklyMemory: LastSeenWindowStore? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
        self.weeklyMemory = weeklyMemory
        self.clock = clock
    }

    public convenience init(config: MetaConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 300) throws {
        let cache = try DiskCache.defaultFor(.meta, ttl: cacheTTL)
        self.init(credentials: MetaCredentialReader(config: config),
                  cache: cache, http: http,
                  // Best-effort: an unwritable directory costs the carried
                  // weekly bar, not the live numbers.
                  weeklyMemory: try? LastSeenWindowStore.defaultFor(.meta))
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
                // resolve() does Keychain + file I/O: keep it off the
                // cooperative pool.
                let resolution = try await OffPool.run { self.credentials.resolve() }
                let token: String
                let fromStoredCopy: Bool
                switch resolution {
                case .token(let value):
                    token = value
                    fromStoredCopy = false
                case .storedToken(let value):
                    token = value
                    fromStoredCopy = true
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
                    // Meta refused the token. If it was the app's stored
                    // copy, drop it so the next read goes back to the
                    // Keychain (a new `muse login` minted another token).
                    // 401 = the token is dead. Any copy of it goes (a live
                    // token's copy too). Only when the copy is what we sent
                    // does it mean "authorize again"; a dead LIVE token is a
                    // dead login and surfaces as the plain 401 (re-login).
                    // 403 is not proof of a dead token: the copy stays.
                    if response.statusCode == 401,
                       credentials.discardStoredToken(token),
                       fromStoredCopy {
                        throw AppError.credentials(
                            "Muse stored token rejected; keychain read denied (errSecInteractionNotAllowed)")
                    }
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
                // Remember a LIVE weekly reading only (never a cached or
                // carried one), so the carry below can stand in for it.
                if let weekly = snapshot.weekly {
                    weeklyMemory?.record(weekly, at: clock())
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
            // The cache holds the response as Meta sent it; the carried
            // weekly is applied on every read so it expires at its reset.
            let snapshot = try SharedCoders.decoder.decode(MetaSnapshot.self, from: data)
            return .meta(snapshot.carryingWeekly(weeklyMemory?.carried(at: clock())))
        } catch {
            throw AppError.schema("meta snapshot decode: \(error)")
        }
    }
}
