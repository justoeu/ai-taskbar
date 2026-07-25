import Foundation
import AiTaskbarCore

public final class OpenAIProvider: UsageProvider, @unchecked Sendable {
    public let vendorId: VendorId = .openai
    public var credentialFileURL: URL? { credentials.path }
    private let credentials: FileCredentialReader
    private let fetcher: CachedFetch
    private let http: HTTPClient
    /// When `false`, the provider never performs the OAuth refresh exchange or
    /// writes back to `~/.codex/auth.json` — it reads whatever token the Codex
    /// CLI maintains and lets the CLI own renewal. This avoids rotating the
    /// shared refresh token (which logs other Codex CLI sessions out). See
    /// `OpenAIConfig.manageOAuthRefresh` for the full rationale.
    private let manageOAuthRefresh: Bool
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    // Memoize the plan label keyed on the id_token. Reading auth.json + a
    // base64url JWT decode on every cache hit was wasteful; now we re-compute
    // only when the token actually rotates (i.e. after a refresh).
    private let labelLock = NSLock()
    private var labelCache: (idToken: String, label: String?)?

    public init(credentials: FileCredentialReader = .init(),
                cache: DiskCache,
                http: HTTPClient,
                manageOAuthRefresh: Bool = false) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
        self.manageOAuthRefresh = manageOAuthRefresh
    }

    public convenience init(http: HTTPClient = .init(),
                            codexAuthPath: URL? = nil,
                            manageOAuthRefresh: Bool = false,
                            cacheTTL: TimeInterval = 300) throws {
        let cache = try DiskCache.defaultFor(.openai, ttl: cacheTTL)
        self.init(
            credentials: FileCredentialReader(path: codexAuthPath ?? Paths.defaultCodexAuth()),
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
                var auth = try credentials.read()
                var didRefresh = false
                // Proactive: refresh ~5 min before the JWT expires (opt-in
                // only). In read-only mode we use whatever token the Codex CLI
                // maintains; a briefly-expired token 401s and CachedFetch
                // serves the last cached snapshot (or surfaces the error when
                // the cache is cold) until the CLI renews — keeping the
                // monitor from logging out Codex sessions.
                if manageOAuthRefresh,
                   let exp = JWT.expiry(auth.tokens.idToken),
                   exp < Date.now.addingTimeInterval(OpenAIOAuth.refreshBuffer) {
                    auth = try await refreshAndWriteBack(auth)
                    didRefresh = true
                }
                // Reactive: if the usage endpoint rejects the token with 401,
                // do a one-shot refresh + retry. Catches the case where the
                // JWT looked valid but the access_token was invalidated
                // server-side (clock skew, early revocation, proactive-refresh
                // window miss). Opt-in only — in read-only mode the 401
                // propagates to CachedFetch unchanged. Skipped when we already
                // refreshed proactively above: a second rotation can't fix an
                // account-level rejection and just churns the shared token.
                do {
                    return try await fetchUsageBytes(auth: auth)
                } catch AppError.http(401, _) where manageOAuthRefresh && !didRefresh {
                    try Task.checkCancellation()
                    auth = try await refreshAndWriteBack(auth)
                    return try await fetchUsageBytes(auth: auth)
                }
            }
        )
    }

    /// Exchanges the refresh_token for fresh access/id tokens and persists the
    /// rotated credential to `~/.codex/auth.json`. Returns the updated auth.
    /// Opt-in only — see `manageOAuthRefresh`.
    private func refreshAndWriteBack(_ auth: CodexAuth) async throws -> CodexAuth {
        let resp = try await OpenAIOAuth.refresh(
            refreshToken: auth.tokens.refreshToken, http: http)
        try Task.checkCancellation()
        var updated = auth
        updated.tokens = CodexTokens(
            accessToken: resp.access_token,
            refreshToken: resp.refresh_token ?? auth.tokens.refreshToken,
            idToken: resp.id_token ?? auth.tokens.idToken
        )
        try credentials.writeBack(updated)
        return updated
    }

    /// Builds the usage request with the given credential and returns the
    /// PII-scrubbed payload bytes.
    private func fetchUsageBytes(auth: CodexAuth) async throws -> Data {
        primeLabelCache(idToken: auth.tokens.idToken)
        var req = URLRequest(url: Self.usageURL)
        req.timeoutInterval = 10
        req.setValue("Bearer \(auth.tokens.accessToken)",
                     forHTTPHeaderField: "Authorization")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let acc = auth.accountId {
            req.setValue(acc, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let rawBytes = try await http.fetchPayload(req)
        return try Self.stripPII(from: rawBytes)
    }

    /// Removes identifying fields from the response before persisting it to
    /// `~/Library/Caches/ai-taskbar/openai/usage.json`. Delegates to the
    /// shared `PIIScrub` so the success path and `CachedFetch`'s error path
    /// (which writes `.last_error`) cannot drift apart — they did: only this
    /// one was scrubbed.
    public static func stripPII(from raw: Data) throws -> Data {
        PIIScrub.scrub(bytes: raw)
    }

    private func decodeSnapshot(_ data: Data) throws -> VendorSnapshot {
        let parsed: OpenAIUsageResponse
        do {
            parsed = try SharedCoders.decoder.decode(OpenAIUsageResponse.self, from: data)
        } catch {
            throw AppError.schema("openai usage decode: \(error)")
        }
        return .openai(parsed.toSnapshot(planLabel: planLabel()))
    }

    /// Returns the cached plan label when valid. Falls back to reading the
    /// credentials file on cache miss (e.g. first call before any fetch).
    private func planLabel() -> String? {
        labelLock.lock()
        let cached = labelCache
        labelLock.unlock()
        if let cached { return cached.label }
        // Cache miss — populate from a fresh read.
        guard let auth = try? credentials.read() else { return nil }
        primeLabelCache(idToken: auth.tokens.idToken)
        labelLock.lock()
        defer { labelLock.unlock() }
        return labelCache?.label
    }

    private func primeLabelCache(idToken: String) {
        labelLock.lock()
        if let cached = labelCache, cached.idToken == idToken {
            labelLock.unlock()
            return
        }
        labelLock.unlock()
        let label = Self.computePlanLabel(from: idToken)
        labelLock.lock()
        labelCache = (idToken: idToken, label: label)
        labelLock.unlock()
    }

    public static func computePlanLabel(from idToken: String) -> String? {
        if let plan: String = JWT.claim(
            idToken,
            key: "https://api.openai.com/auth.chatgpt_plan_type",
            as: String.self) {
            return labelForPlan(plan)
        }
        return nil
    }

    private static func labelForPlan(_ plan: String) -> String {
        switch plan.lowercased() {
        case "free":       return "ChatGPT Free"
        case "plus":       return "ChatGPT Plus"
        case "pro":        return "ChatGPT Pro"
        case "team":       return "ChatGPT Team"
        case "enterprise": return "ChatGPT Enterprise"
        default:           return "ChatGPT \(plan.capitalized)"
        }
    }
}
