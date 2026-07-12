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
        try await fetcher.run(
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

    private func loadCredentials() async throws -> AnthropicCredentials {
        var credentials = try credentialReader.read()
        // Only rotate + persist the shared OAuth token when explicitly opted
        // in. Read-only mode merely reloads whatever Claude Code owns.
        if manageOAuthRefresh, credentials.isExpired(buffer: AnthropicOAuth.refreshBuffer) {
            let resp = try await AnthropicOAuth.refresh(
                refreshToken: credentials.refreshToken, http: http)
            try Task.checkCancellation()
            credentials = credentials.rotated(
                accessToken: resp.access_token,
                refreshToken: resp.refresh_token,
                expiresAt: Date.now.addingTimeInterval(resp.expires_in))
            try credentialReader.writeBack(credentials)
        }
        return credentials
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

    /// Invoked only from the explicit Authorize button. The concrete
    /// Keychain reader permits the native prompt and caches the credential in
    /// memory; mocks use the protocol's non-interactive default.
    public func authorizeCredentialsInteractively() throws {
        _ = try credentialReader.readInteractively()
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

    private func planLabel() -> String? {
        labelLock.lock()
        let cached = labelCache
        labelLock.unlock()
        if let cached { return cached.label }
        guard let credentials = try? credentialReader.read() else { return nil }
        primeLabelCache(subscriptionType: credentials.subscriptionType,
                        rateLimit: credentials.rateLimitTier)
        labelLock.lock()
        defer { labelLock.unlock() }
        return labelCache?.label
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
