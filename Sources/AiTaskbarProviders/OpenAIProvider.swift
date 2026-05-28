import Foundation
import AiTaskbarCore

public final class OpenAIProvider: UsageProvider, @unchecked Sendable {
    public let vendorId: VendorId = .openai
    private let credentials: FileCredentialReader
    private let fetcher: CachedFetch
    private let http: HTTPClient
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// PII fields the upstream response carries that we strip before caching
    /// to disk. These travel back to the user via the `user_id`/`account_id`/
    /// `email` triple — none of which we need for the snapshot.
    private static let piiFieldsToStrip: Set<String> = [
        "user_id", "account_id", "email",
    ]

    // Memoize the plan label keyed on the id_token. Reading auth.json + a
    // base64url JWT decode on every cache hit was wasteful; now we re-compute
    // only when the token actually rotates (i.e. after a refresh).
    private let labelLock = NSLock()
    private var labelCache: (idToken: String, label: String?)?

    public init(credentials: FileCredentialReader = .init(),
                cache: DiskCache,
                http: HTTPClient) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
    }

    public convenience init(http: HTTPClient = .init(),
                            codexAuthPath: URL? = nil,
                            cacheTTL: TimeInterval = 150) throws {
        let cache = try DiskCache.defaultFor(.openai, ttl: cacheTTL)
        self.init(
            credentials: FileCredentialReader(path: codexAuthPath ?? Paths.defaultCodexAuth()),
            cache: cache,
            http: http
        )
    }

    public func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        try await fetcher.run(
            forceRefresh: forceRefresh,
            decode: decodeSnapshot,
            fetch: { [self] in
                var auth = try credentials.read()
                if let exp = JWT.expiry(auth.tokens.idToken),
                   exp < Date.now.addingTimeInterval(OpenAIOAuth.refreshBuffer) {
                    let resp = try await OpenAIOAuth.refresh(
                        refreshToken: auth.tokens.refreshToken, http: http)
                    try Task.checkCancellation()
                    auth.tokens = CodexTokens(
                        accessToken: resp.access_token,
                        refreshToken: resp.refresh_token ?? auth.tokens.refreshToken,
                        idToken: resp.id_token ?? auth.tokens.idToken
                    )
                    try credentials.writeBack(auth)
                }
                // Refresh the memoized label whenever we have fresh auth.
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
        )
    }

    /// Removes `user_id`, `account_id`, `email` from the top-level response
    /// object before persisting. Parses via `[String: JSONValue]` for type
    /// safety; falls back to returning the raw bytes if the response isn't a
    /// JSON object.
    public static func stripPII(from raw: Data) throws -> Data {
        guard var blob = try? SharedCoders.decoder.decode([String: JSONValue].self, from: raw) else {
            return raw
        }
        for field in piiFieldsToStrip {
            blob.removeValue(forKey: field)
        }
        return try SharedCoders.encoder.encode(blob)
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
