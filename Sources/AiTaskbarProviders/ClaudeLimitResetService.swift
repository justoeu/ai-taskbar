import Foundation
import AiTaskbarCore

/// Errors a Claude limit reset can end in. `submissionUncertain` is the only
/// one after which the SAME attempt (same `request_id`) may be retried.
public enum ClaudeLimitResetError: Error, Equatable, Sendable {
    /// No Claude Code CLI installed: the server serves resets to it only.
    case cliUnavailable
    case noEligibleReset
    case accountChanged
    case authorization
    case rateLimited
    case submissionUncertain
    case failed
}

/// One user-confirmed attempt. `id` is the claim's `request_id`, kept across
/// retries so a retry cannot spend a second reset.
public struct ClaudeLimitResetAttempt: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: ClaudeResetKind
    public let grantID: String
    public let grantLabel: String
    public let resetsLeft: Int
    public let accountUUID: String
    public let organizationUUID: String

    public init(id: UUID = UUID(), kind: ClaudeResetKind, grantID: String, grantLabel: String,
                resetsLeft: Int, accountUUID: String, organizationUUID: String) {
        self.id = id
        self.kind = kind
        self.grantID = grantID
        self.grantLabel = grantLabel
        self.resetsLeft = resetsLeft
        self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID
    }

    /// `^[A-Za-z0-9_-]{1,64}$`, as Claude Code requires.
    public var requestID: String { id.uuidString.lowercased() }
}

public enum ClaudeLimitResetOutcome: String, Sendable, Equatable {
    case reset
    case alreadyUsed = "already_used"
    case notLimited = "not_limited"
    case cooldown
    case ineligible
    case unavailable
}

public struct ClaudeLimitResetReceipt: Sendable, Equatable {
    public let outcome: ClaudeLimitResetOutcome
    public let resetsLeft: Int?

    public init(outcome: ClaudeLimitResetOutcome, resetsLeft: Int?) {
        self.outcome = outcome
        self.resetsLeft = resetsLeft
    }
}

/// Claude Code's `/limit-reset` protocol (program `cedar_ember`), measured in
/// CLI 2.1.322 on 2026-11-12 (`docs/SDD-claude-limit-reset.md`):
///
/// - status: `GET /api/oauth/usage?cedar_ember=1` → `cedar_ember.grants`
/// - claim: `POST /api/organizations/{org}/reset_rate_limits` with
///   `{program, grant_id, request_id}` → `{result, reason, resets_left, ...}`
///
/// Read-only on the shared credential: never refreshes or writes it back.
/// The organization comes from `/api/oauth/profile` for the SAME token (only
/// the two UUIDs are decoded — never name or e-mail), so it cannot drift from
/// the account the token belongs to.
public final class ClaudeLimitResetService: Sendable {
    static let base = URL(string: "https://api.anthropic.com")!
    static let program = "cedar_ember"

    private let credentialReader: any AnthropicCredentialReading
    private let http: HTTPClient
    private let cliVersion: @Sendable () -> String?
    private let now: @Sendable () -> Date

    public init(credentialReader: any AnthropicCredentialReading,
                http: HTTPClient,
                cliVersion: @escaping @Sendable () -> String? = { ClaudeCLIVersion.installed() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentialReader = credentialReader
        self.http = http
        self.cliVersion = cliVersion
        self.now = now
    }

    /// Re-reads everything on click: the card may be up to five minutes old.
    public func prepare(kind: ClaudeResetKind) async throws -> ClaudeLimitResetAttempt {
        let context = try await context()
        let identity = try await profile(context)
        let snapshot = try await status(context)
        guard let offer = snapshot.limitResetOffers(now: now()).first(where: { $0.kind == kind }) else {
            throw ClaudeLimitResetError.noEligibleReset
        }
        return ClaudeLimitResetAttempt(kind: kind, grantID: offer.grant.id, grantLabel: offer.grant.label,
                                       resetsLeft: offer.resetsLeft,
                                       accountUUID: identity.account, organizationUUID: identity.organization)
    }

    public func consume(_ attempt: ClaudeLimitResetAttempt, retry: Bool) async throws -> ClaudeLimitResetReceipt {
        let context = try await context()
        let identity = try await profile(context)
        guard identity.account == attempt.accountUUID, identity.organization == attempt.organizationUUID else {
            throw ClaudeLimitResetError.accountChanged
        }
        if !retry {
            // Same gate as the first click; a retry re-sends the attempt
            // already submitted, which the server dedupes by request_id.
            let snapshot = try await status(context)
            let stillOffered = snapshot.limitResetOffers(now: now()).contains {
                $0.kind == attempt.kind && snapshot.resetGrants.contains { $0.id == attempt.grantID && $0.isUsable(now: now()) }
            }
            guard stillOffered else { throw ClaudeLimitResetError.noEligibleReset }
        }
        try Task.checkCancellation()
        return try await claim(attempt, context: context)
    }

    // MARK: - Calls

    struct Context {
        let token: String
        let userAgent: String
    }

    private func context() async throws -> Context {
        let cliVersion = self.cliVersion
        // File metadata reads: off the cooperative pool, as in the provider.
        guard let version = try await OffPool.run({ cliVersion() }),
              let agent = ClaudeCLIVersion.userAgent(version: version) else {
            throw ClaudeLimitResetError.cliUnavailable
        }
        let credentials: AnthropicCredentials
        do {
            credentials = try await credentialReader.readOffPool()
        } catch {
            AppLog.network.error("claude reset: credential read failed: \(String(describing: error), privacy: .public)")
            throw ClaudeLimitResetError.authorization
        }
        try Task.checkCancellation()
        return Context(token: credentials.accessToken, userAgent: agent)
    }

    private func request(_ path: String, _ context: Context, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: path, relativeTo: Self.base)!.absoluteURL)
        req.httpMethod = method
        req.timeoutInterval = method == "GET" ? 10 : 25
        req.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        req.setValue(AnthropicOAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(context.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    /// Definitive rejections before anything was spent.
    private func checked(_ data: Data, _ response: HTTPURLResponse, what: String) throws -> Data {
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw ClaudeLimitResetError.authorization
        case 429: throw ClaudeLimitResetError.rateLimited
        default:
            AppLog.network.error("claude reset: \(what, privacy: .public) HTTP \(response.statusCode)")
            throw ClaudeLimitResetError.failed
        }
    }

    private struct Profile: Decodable {
        struct Ref: Decodable { let uuid: String? }
        let account: Ref?
        let organization: Ref?
    }

    struct Identity: Equatable {
        let account: String
        let organization: String
    }

    func profile(_ context: Context) async throws -> Identity {
        let (data, response) = try await sendDefinitive(request("/api/oauth/profile", context), what: "profile")
        let body = try checked(data, response, what: "profile")
        let decoded: Profile
        do {
            decoded = try SharedCoders.decoder.decode(Profile.self, from: body)
        } catch {
            AppLog.network.error("claude reset: profile decode failed: \(String(describing: error), privacy: .public)")
            throw ClaudeLimitResetError.failed
        }
        guard let account = decoded.account?.uuid.flatMap(Self.canonicalUUID),
              let organization = decoded.organization?.uuid.flatMap(Self.canonicalUUID) else {
            AppLog.network.error("claude reset: profile without account/organization uuid")
            throw ClaudeLimitResetError.failed
        }
        return Identity(account: account, organization: organization)
    }

    func status(_ context: Context) async throws -> AnthropicSnapshot {
        let (data, response) = try await sendDefinitive(request("/api/oauth/usage?cedar_ember=1", context), what: "status")
        let body = try checked(data, response, what: "status")
        do {
            return try SharedCoders.decoder.decode(AnthropicUsageResponse.self, from: body).toSnapshot(planLabel: nil)
        } catch {
            AppLog.network.error("claude reset: status decode failed: \(String(describing: error), privacy: .public)")
            throw ClaudeLimitResetError.failed
        }
    }

    private struct ClaimBody: Encodable {
        let program: String
        let grant_id: String
        let request_id: String
    }

    private struct ClaimResponse: Decodable {
        let result: String?
        let resets_left: Double?
    }

    func claim(_ attempt: ClaudeLimitResetAttempt, context: Context) async throws -> ClaudeLimitResetReceipt {
        guard AnthropicResetGrant.isValidID(attempt.grantID),
              let org = Self.canonicalUUID(attempt.organizationUUID) else {
            throw ClaudeLimitResetError.failed
        }
        let body = try JSONEncoder().encode(ClaimBody(program: Self.program, grant_id: attempt.grantID,
                                                      request_id: attempt.requestID))
        let req = request("/api/organizations/\(org)/reset_rate_limits", context, method: "POST", body: body)
        let data: Data
        let response: HTTPURLResponse
        do {
            // Same-origin HTTPS redirects only: a 307 elsewhere would re-send
            // the POST and its answer would be read as the claim result.
            (data, response) = try await http.sendBounded(req, maximumResponseBytes: 64 * 1024)
        } catch is CancellationError {
            throw ClaudeLimitResetError.submissionUncertain
        } catch {
            // The request may have reached the server: only a retry with the
            // same request_id is safe.
            AppLog.network.error("claude reset: claim transport: \(String(describing: error), privacy: .public)")
            throw ClaudeLimitResetError.submissionUncertain
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw ClaudeLimitResetError.authorization
        case 429: throw ClaudeLimitResetError.rateLimited
        case 500...: throw ClaudeLimitResetError.submissionUncertain
        default:
            AppLog.network.error("claude reset: claim HTTP \(response.statusCode)")
            throw ClaudeLimitResetError.failed
        }
        let decoded: ClaimResponse
        do {
            decoded = try SharedCoders.decoder.decode(ClaimResponse.self, from: data)
        } catch {
            AppLog.network.error("claude reset: claim answer unreadable: \(String(describing: error), privacy: .public)")
            throw ClaudeLimitResetError.submissionUncertain
        }
        guard let raw = decoded.result else {
            AppLog.network.error("claude reset: claim answer without result")
            throw ClaudeLimitResetError.submissionUncertain
        }
        // An unknown result is not a reset: Claude Code reads it as "unavailable".
        let outcome = ClaudeLimitResetOutcome(rawValue: raw) ?? .unavailable
        return ClaudeLimitResetReceipt(outcome: outcome,
                                       resetsLeft: decoded.resets_left.flatMap { Int(checkedTruncating: $0) })
    }

    /// Reads that spend nothing: a transport failure is just a failure.
    private func sendDefinitive(_ request: URLRequest, what: String) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await http.sendBounded(request, maximumResponseBytes: HTTPClient.defaultMaximumResponseBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLog.network.error("claude reset: \(what, privacy: .public) transport: \(String(describing: error), privacy: .public)")
            throw ClaudeLimitResetError.failed
        }
    }

    /// Lowercased canonical form, nil for anything that is not a UUID (the
    /// value goes into a URL path).
    static func canonicalUUID(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString.lowercased()
    }
}
