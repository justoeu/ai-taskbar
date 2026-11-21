import Foundation
import AiTaskbarCore

/// Requests shared by `ZAIProvider` and `ZAILimitResetService`: one host,
/// one header shape (the raw API key, no "Bearer").
enum ZAIRequests {
    static let usageURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    static let resetListURL = URL(string: "https://api.z.ai/api/biz/customer-package-reset/list?targetType=PERSONAL")!
    static let resetUseURL = URL(string: "https://api.z.ai/api/biz/customer-package-reset/use")!
    /// The list and the use answer are a few hundred bytes.
    static let resetResponseLimit = 256 * 1024

    static func request(_ url: URL, apiKey: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = method == "GET" ? 10 : 25
        // **NO** "Bearer " prefix — the usage endpoint rejects it with 401.
        req.setValue(apiKey, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        req.httpBody = body
        return req
    }
}

/// Errors a Z.AI quota reset can end in. A server ANSWER to the use call is
/// a `ZAILimitResetReceipt`, not an error, so the card refreshes after it.
public enum ZAILimitResetError: Error, Equatable, Sendable {
    case noEligibleReset
    case authorization
    case rateLimited
    /// The request may have reached the server: only a retry with the SAME
    /// `requestId` is safe.
    case submissionUncertain
    case failed
}

/// One user-confirmed attempt. `id` is the use call's `requestId`, kept
/// across retries so a retry cannot spend a second reset (the console keeps
/// it the same way until the server answers).
public struct ZAILimitResetAttempt: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: ZAIResetKind
    public let recordID: Int64
    public let grantType: String?
    public let expiresAt: String?
    public let resetsLeft: Int

    public init(id: UUID = UUID(), kind: ZAIResetKind, recordID: Int64, grantType: String?,
                expiresAt: String?, resetsLeft: Int) {
        self.id = id
        self.kind = kind
        self.recordID = recordID
        self.grantType = grantType
        self.expiresAt = expiresAt
        self.resetsLeft = resetsLeft
    }

    public var requestID: String { id.uuidString.lowercased() }
}

/// The server's answer to a use call.
public struct ZAILimitResetReceipt: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// `code: 200`, `success: true`.
        case reset
        /// Any other answer to a FIRST attempt: nothing was spent (the
        /// console clears its requestId on it too).
        case refused
        /// Any other answer to a RETRY: the earlier, lost attempt may have
        /// been applied, and whether Z.AI answers a repeated requestId with
        /// success is not known, so "nothing was spent" cannot be claimed.
        case unconfirmed
    }

    public let kind: ZAIResetKind
    public let outcome: Outcome

    public init(kind: ZAIResetKind, outcome: Outcome = .reset) {
        self.kind = kind
        self.outcome = outcome
    }
}

/// The console's "Reset Quota" (`docs/SDD-zai-quota-reset.md`), read from
/// its bundle on 2026-11-21 and checked against the live list with an API
/// key:
///
/// - list: `GET /api/biz/customer-package-reset/list?targetType=PERSONAL`
/// - use: `POST /api/biz/customer-package-reset/use` with
///   `{targetType, resetType, recordId, requestId, grantType}` →
///   `{code, msg, success}`
public final class ZAILimitResetService: Sendable {
    static let targetType = "PERSONAL"

    private let credentials: EnvOrConfigCredentialReader
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    public init(credentials: EnvOrConfigCredentialReader,
                http: HTTPClient,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.http = http
        self.now = now
    }

    /// Re-reads usage and the list on click: the card may be five minutes old.
    public func prepare(kind: ZAIResetKind) async throws -> ZAILimitResetAttempt {
        let key = try apiKey()
        let snapshot = try await status(key)
        guard let offer = snapshot.limitResetOffers(now: now()).first(where: { $0.kind == kind }) else {
            throw ZAILimitResetError.noEligibleReset
        }
        return ZAILimitResetAttempt(kind: kind, recordID: offer.grant.recordID, grantType: offer.grant.grantType,
                                    expiresAt: offer.grant.expiresAt, resetsLeft: offer.resetsLeft)
    }

    public func consume(_ attempt: ZAILimitResetAttempt, retry: Bool) async throws -> ZAILimitResetReceipt {
        let key = try apiKey()
        if !retry {
            // Same gate as the click: the record is still unused and a window
            // it refills is still above 90%. A retry re-sends the attempt
            // already submitted, which the server dedupes by requestId.
            let snapshot = try await status(key)
            let stillOffered = snapshot.limitResetOffers(now: now()).contains { $0.kind == attempt.kind }
                && snapshot.resetGrants.contains { $0.kind == attempt.kind && $0.recordID == attempt.recordID }
            guard stillOffered else { throw ZAILimitResetError.noEligibleReset }
        }
        try Task.checkCancellation()
        return try await use(attempt, apiKey: key, retry: retry)
    }

    // MARK: - Calls

    private func apiKey() throws -> String {
        do {
            return try credentials.read()
        } catch {
            AppLog.network.error("zai reset: no API key: \(String(describing: error), privacy: .public)")
            throw ZAILimitResetError.authorization
        }
    }

    /// Fresh usage windows plus the reset list. Spends nothing.
    func status(_ apiKey: String) async throws -> ZAISnapshot {
        let usage = try await read(ZAIRequests.usageURL, apiKey: apiKey, what: "usage",
                                   limit: HTTPClient.defaultMaximumResponseBytes)
        let list = try await read(ZAIRequests.resetListURL, apiKey: apiKey, what: "list",
                                  limit: ZAIRequests.resetResponseLimit)
        let envelope: ZAIEnvelope
        let listStatus: Answer
        let resets: ZAIResetList?
        do {
            envelope = try SharedCoders.decoder.decode(ZAIEnvelope.self, from: usage)
            listStatus = try SharedCoders.decoder.decode(Answer.self, from: list)
            resets = try ZAIResetList.decodeResponse(list)
        } catch {
            AppLog.network.error("zai reset: status decode failed: \(String(describing: error), privacy: .public)")
            throw ZAILimitResetError.failed
        }
        try Self.checkBody(code: envelope.code, success: envelope.success, what: "usage")
        try Self.checkBody(code: listStatus.code, success: listStatus.success, what: "list")
        guard let resets, envelope.data != nil else {
            AppLog.network.error("zai reset: usage or list without data")
            throw ZAILimitResetError.failed
        }
        return ZAIEnvelope(code: envelope.code, data: envelope.data, resetList: resets).toSnapshot(configTier: nil)
    }

    private struct UseBody: Encodable {
        let targetType: String
        let resetType: String
        let recordId: Int64
        let requestId: String
        let grantType: String?
    }

    /// Z.AI's `{code, msg, success}` answer shape (list and use).
    private struct Answer: Decodable {
        let code: Int?
        let msg: String?
        let success: Bool?
    }

    func use(_ attempt: ZAILimitResetAttempt, apiKey: String, retry: Bool) async throws -> ZAILimitResetReceipt {
        guard attempt.recordID > 0,
              attempt.grantType.map(ZAIResetGrant.isValidGrantType) ?? true else {
            throw ZAILimitResetError.failed
        }
        let body = try SharedCoders.encoder.encode(UseBody(targetType: Self.targetType, resetType: attempt.kind.rawValue,
                                                    recordId: attempt.recordID, requestId: attempt.requestID,
                                                    grantType: attempt.grantType))
        let req = ZAIRequests.request(ZAIRequests.resetUseURL, apiKey: apiKey, method: "POST", body: body)
        let data: Data
        let response: HTTPURLResponse
        do {
            // Same-origin HTTPS redirects only: a 307 elsewhere would re-send
            // the POST and its answer would be read as the use result.
            (data, response) = try await http.sendBounded(req, maximumResponseBytes: ZAIRequests.resetResponseLimit)
        } catch {
            // The request may have reached the server (cancellation included):
            // only a retry with the same requestId is safe.
            AppLog.network.error("zai reset: use transport: \(String(describing: error), privacy: .public)")
            throw ZAILimitResetError.submissionUncertain
        }
        try Self.checkHTTP(response.statusCode, what: "use", uncertainOnServerError: true)
        let decoded: Answer
        do {
            decoded = try SharedCoders.decoder.decode(Answer.self, from: data)
        } catch {
            AppLog.network.error("zai reset: use answer unreadable: \(String(describing: error), privacy: .public)")
            throw ZAILimitResetError.submissionUncertain
        }
        if decoded.code == 200, decoded.success == true {
            return ZAILimitResetReceipt(kind: attempt.kind)
        }
        AppLog.network.error(
            "zai reset: use not confirmed, code \(decoded.code ?? -1): \(PIIScrub.scrub(diagnostic: decoded.msg ?? ""), privacy: .public)")
        switch decoded.code {
        // A 2xx without a code is closer to "unreadable" than to a refusal.
        case nil, .some(500...599): throw ZAILimitResetError.submissionUncertain
        case 401, 403: throw ZAILimitResetError.authorization
        case 429: throw ZAILimitResetError.rateLimited
        default: return ZAILimitResetReceipt(kind: attempt.kind, outcome: retry ? .unconfirmed : .refused)
        }
    }

    /// Reads that spend nothing: a transport failure is just a failure.
    private func read(_ url: URL, apiKey: String, what: String, limit: Int) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.sendBounded(ZAIRequests.request(url, apiKey: apiKey),
                                                         maximumResponseBytes: limit)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLog.network.error("zai reset: \(what, privacy: .public) transport: \(String(describing: error), privacy: .public)")
            throw ZAILimitResetError.failed
        }
        try Self.checkHTTP(response.statusCode, what: what, uncertainOnServerError: false)
        return data
    }

    private static func checkHTTP(_ status: Int, what: String, uncertainOnServerError: Bool) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw ZAILimitResetError.authorization
        case 429: throw ZAILimitResetError.rateLimited
        case 500...599 where uncertainOnServerError: throw ZAILimitResetError.submissionUncertain
        default:
            AppLog.network.error("zai reset: \(what, privacy: .public) HTTP \(status)")
            throw ZAILimitResetError.failed
        }
    }

    /// Z.AI also reports errors in the body (`code` with HTTP 200).
    private static func checkBody(code: Int?, success: Bool?, what: String) throws {
        if (code == nil || code == 200), success != false { return }
        switch code {
        case 401, 403: throw ZAILimitResetError.authorization
        case 429: throw ZAILimitResetError.rateLimited
        default:
            AppLog.network.error("zai reset: \(what, privacy: .public) body code \(code ?? -1)")
            throw ZAILimitResetError.failed
        }
    }
}
