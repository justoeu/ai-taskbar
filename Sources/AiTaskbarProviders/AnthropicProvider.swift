import Foundation
import AiTaskbarCore

public final class AnthropicProvider: UsageProvider, @unchecked Sendable {
    public let vendorId: VendorId = .anthropic
    private let credentialReader: any AnthropicCredentialReading
    private let fetcher: CachedFetch
    private let http: HTTPClient
    /// When `false`, the provider never performs the OAuth refresh exchange or
    /// writes back to the shared Keychain item — it reads whatever token the
    /// Claude Code CLI maintains and lets the CLI own renewal. This avoids
    /// rotating the shared refresh token (which logs other CLI sessions out)
    /// and the ACL prompt write-back triggers on ad-hoc builds. See
    /// `AnthropicConfig.manageOauthRefresh` for the full rationale.
    private let manageOAuthRefresh: Bool
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // Memoize the plan label so we don't make a `SecItemCopyMatching`
    // syscall (read + JSON decode of the credentials blob) on every cache
    // hit. Keyed on the tuple of fields used to compute the label.
    private let labelLock = NSLock()
    private var labelCache: (key: String, label: String?)?

    public init(credentialReader: any AnthropicCredentialReading = KeychainCredentialReader(),
                cache: DiskCache,
                http: HTTPClient,
                manageOAuthRefresh: Bool = false) {
        self.credentialReader = credentialReader
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
        self.manageOAuthRefresh = manageOAuthRefresh
    }

    public convenience init(http: HTTPClient = .init(),
                            keychainService: String = "Claude Code-credentials",
                            keychainAccount: String? = nil,
                            manageOAuthRefresh: Bool = false,
                            cacheTTL: TimeInterval = 300) throws {
        let cache = try DiskCache.defaultFor(.anthropic, ttl: cacheTTL)
        self.init(
            credentialReader: KeychainCredentialReader(service: keychainService,
                                                       preferredAccount: keychainAccount),
            cache: cache,
            http: http,
            manageOAuthRefresh: manageOAuthRefresh
        )
    }

    public func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        // A cache hit decodes synchronously, so the plan label must already
        // be memoized: reading the Keychain from decode would block a
        // cooperative-pool thread (RACE-CRO-004). The fetch path primes it
        // from its own read. Priming only when a fresh entry will actually be
        // served keeps a cold fetch to ONE Keychain read, and bounds a failing
        // priming read to the fresh hits of one TTL instead of every tick: once
        // the entry ages out, the fetch path reads and surfaces the error
        // (PERF-MAE-003).
        if !forceRefresh, fetcher.cache.hasFreshPayload() {
            await primeLabelCacheOffPoolIfNeeded()
        }
        return try await fetcher.run(
            forceRefresh: forceRefresh,
            decode: decodeSnapshot,
            fetch: { [self] in
                let credentials = try await loadCredentials()
                primeLabelCache(subscriptionType: credentials.subscriptionType,
                                rateLimit: credentials.rateLimitTier)
                do {
                    return try await requestUsage(using: credentials)
                } catch let error as AppError where error.isUnauthorized {
                    // Claude Code can rotate/revoke an access token before its
                    // advertised expiry. Drop the process cache and re-read
                    // once. If Claude also restored its private Keychain ACL,
                    // `read()` now throws the actionable ACL error so the stale
                    // snapshot displays Authorize instead of a misleading 401.
                    credentialReader.invalidateCachedCredentials()
                    try Task.checkCancellation()
                    let reloaded = try await loadCredentials()
                    primeLabelCache(subscriptionType: reloaded.subscriptionType,
                                    rateLimit: reloaded.rateLimitTier)
                    return try await requestUsage(using: reloaded)
                }
            }
        )
    }

    /// Single-flight OAuth refresh (RACE-HER-003, RACE-CRO-001) — same RT
    /// rotation hazard as OpenAI.
    private let refreshFlight = SingleFlight<AnthropicCredentials>()

    private func loadCredentials() async throws -> AnthropicCredentials {
        var credentials = try await credentialReader.readOffPool()
        // Only rotate + persist the shared OAuth token when explicitly opted
        // in. Read-only mode merely reloads whatever Claude Code owns.
        // A credential served by the /usr/bin/security fallback cannot be
        // written back; rotating it would strand the new refresh token in
        // memory and invalidate the one the Claude Code CLI still holds.
        if manageOAuthRefresh, credentialReader.canPersistCredentials,
           credentials.isExpired(buffer: AnthropicOAuth.refreshBuffer) {
            credentials = try await refreshAndWriteBack(credentials)
            try Task.checkCancellation()
        }
        return credentials
    }

    private func refreshAndWriteBack(_ credentials: AnthropicCredentials) async throws -> AnthropicCredentials {
        try await refreshFlight.run { [self] in
            // The caller's credential may predate a rotation by an earlier
            // flight or by the Claude Code CLI; exchanging its refresh token
            // would spend one the server already consumed (RACE-CRO-002).
            // No invalidate first: the reader's memory cache only serves a
            // credential outside the refresh window (both buffers are 300 s),
            // i.e. a newer one, and invalidating would drop a pending,
            // not-yet-persisted rotation.
            let current = try await credentialReader.readOffPool()
            // The re-read may have fallen back to /usr/bin/security, which
            // cannot write back; never rotate what cannot be persisted.
            if current.refreshToken != credentials.refreshToken
                || !credentialReader.canPersistCredentials {
                return current
            }
            let resp = try await AnthropicOAuth.refresh(
                refreshToken: current.refreshToken, http: http)
            // No cancellation check here: the flight is never cancelled (see
            // SingleFlight), and once the server rotated the token the new
            // one must be written back. `loadCredentials` checks afterwards.
            let updated = current.rotated(
                accessToken: resp.access_token,
                refreshToken: resp.refresh_token,
                expiresAt: Date.now.addingTimeInterval(resp.expires_in))
            try credentialReader.writeBack(updated)
            return updated
        }
    }

    private func requestUsage(using credentials: AnthropicCredentials) async throws -> Data {
        var req = URLRequest(url: Self.usageURL)
        req.timeoutInterval = 10
        req.setValue("Bearer \(credentials.accessToken)",
                     forHTTPHeaderField: "Authorization")
        req.setValue(AnthropicOAuth.betaHeader,
                     forHTTPHeaderField: "anthropic-beta")
        req.setValue(AnthropicOAuth.userAgent,
                     forHTTPHeaderField: "User-Agent")
        let payload = try await http.fetchPayload(req)
        try Task.checkCancellation()
        return payload
    }

    /// Invoked only from the explicit Authorize button. The concrete reader
    /// grants this stable signing identity durable access to the shared
    /// Keychain item, then verifies a silent read. A canceled native dialog
    /// returns false so the UI leaves the existing banner untouched.
    @discardableResult
    public func authorizeCredentialsInteractively() throws -> Bool {
        try credentialReader.authorizePersistently() == .authorized
    }

    private func decodeSnapshot(_ data: Data) throws -> VendorSnapshot {
        let parsed: AnthropicUsageResponse
        do {
            parsed = try SharedCoders.decoder.decode(AnthropicUsageResponse.self, from: data)
        } catch {
            throw AppError.schema("anthropic usage decode: \(error)")
        }
        return .anthropic(parsed.toSnapshot(planLabel: planLabel()))
    }

    /// Memoized only. Decode runs synchronously on the caller's executor, so
    /// it must never touch the Keychain.
    private func planLabel() -> String? {
        labelLock.lock()
        defer { labelLock.unlock() }
        return labelCache?.label
    }

    /// Best-effort: a failed read only costs the plan label on this cache
    /// hit. The fetch path reads again and surfaces credential errors.
    private func primeLabelCacheOffPoolIfNeeded() async {
        guard !labelLock.withLock({ labelCache != nil }),
              let credentials = try? await credentialReader.readOffPool() else { return }
        primeLabelCache(subscriptionType: credentials.subscriptionType,
                        rateLimit: credentials.rateLimitTier)
    }

    private func primeLabelCache(subscriptionType: String?, rateLimit: String?) {
        let key = "\(subscriptionType ?? "")|\(rateLimit ?? "")"
        labelLock.lock()
        if let cached = labelCache, cached.key == key {
            labelLock.unlock()
            return
        }
        labelLock.unlock()
        let label = Self.credLabel(subscriptionType: subscriptionType, rateLimit: rateLimit)
        labelLock.lock()
        labelCache = (key: key, label: label)
        labelLock.unlock()
    }

    public static func credLabel(subscriptionType: String?, rateLimit: String?) -> String? {
        switch subscriptionType?.lowercased() {
        case "max":
            if rateLimit?.contains("20x") == true { return "Claude Max 20x" }
            if rateLimit?.contains("5x")  == true { return "Claude Max 5x" }
            return "Claude Max"
        case "pro":        return "Claude Pro"
        case "team":       return "Claude Team"
        case "enterprise": return "Claude Enterprise"
        case .some(let s) where !s.isEmpty: return "Claude " + s.capitalized
        default: return nil
        }
    }
}
