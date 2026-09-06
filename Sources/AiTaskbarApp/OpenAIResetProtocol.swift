import Foundation
import AiTaskbarCore

/// Documented Codex app-server API, not a private reset HTTP endpoint.
/// https://learn.chatgpt.com/docs/app-server#8-earned-rate-limit-resets-chatgpt
protocol CodexResetRPC: AnyObject {
    func request(_ method: String, params: [String: JSONValue]) throws -> [String: JSONValue]
    func notify(_ method: String) throws
}

enum OpenAIResetError: Error, Equatable {
    case unavailable, protocolFailure, timeout, noEligibleReset, accountChanged, authorization, submissionUncertain, attemptInProgress
    case methodNotFound, consumeUnsupported
}

struct OpenAIResetOffer: Sendable, Identifiable, Equatable, Codable {
    let id: UUID
    let accountID: String
    let accountLabel: String
    let availableCount: Int
    var isRetry = false

    init(accountID: String, accountLabel: String, availableCount: Int, id: UUID = UUID()) {
        self.id = id
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.availableCount = availableCount
    }
}

enum OpenAIResetOutcome: String, Sendable {
    case reset, alreadyRedeemed, nothingToReset, noCredit
}

struct OpenAIResetReceipt: Sendable {
    let outcome: OpenAIResetOutcome
    let limitsRefreshed: Bool
}

enum OpenAIResetProtocol {
    static func prepare(auth: CodexAuth, rpc: any CodexResetRPC) throws -> OpenAIResetOffer {
        let account = try accountID(auth)
        try authenticate(auth, account: account, rpc: rpc)
        let limits = try rpc.request("account/rateLimits/read", params: [:])
        try verifyAccount(limits, expected: account)
        guard let count = eligibleResetCount(limits) else { throw OpenAIResetError.noEligibleReset }
        let email = JWT.claim(auth.tokens.idToken, key: "email", as: String.self)
        // Include the account ID so personal/work workspaces cannot look identical.
        let label = email.map { "\($0) · \(account)" } ?? account
        return OpenAIResetOffer(accountID: account, accountLabel: label, availableCount: count)
    }

    static func consume(auth: CodexAuth, offer: OpenAIResetOffer, retry: Bool,
                        rpc: any CodexResetRPC,
                        beforeDispatch: () throws -> Void = {}) throws -> OpenAIResetReceipt {
        guard try accountID(auth) == offer.accountID else { throw OpenAIResetError.accountChanged }
        try authenticate(auth, account: offer.accountID, rpc: rpc)
        let limits = try rpc.request("account/rateLimits/read", params: [:])
        try verifyAccount(limits, expected: offer.accountID)
        if !retry {
            guard eligibleResetCount(limits) != nil else { throw OpenAIResetError.noEligibleReset }
        }
        // Every user-confirmed logical attempt keeps this same key on retries.
        try beforeDispatch()
        let outcome: OpenAIResetOutcome
        do {
            let response = try rpc.request("account/rateLimitResetCredit/consume", params: [
                "idempotencyKey": .string(offer.id.uuidString)
            ])
            guard let raw = response["outcome"]?.stringValue,
                  let parsed = OpenAIResetOutcome(rawValue: raw) else {
                throw OpenAIResetError.protocolFailure
            }
            outcome = parsed
        } catch OpenAIResetError.methodNotFound {
            // Definitive rejection of THIS consume method, not of an earlier
            // initialize/login/read. A prior ambiguous attempt still survives.
            throw OpenAIResetError.consumeUnsupported
        } catch {
            throw OpenAIResetError.submissionUncertain
        }
        do {
            _ = try rpc.request("account/rateLimits/read", params: [:])
            return OpenAIResetReceipt(outcome: outcome, limitsRefreshed: true)
        } catch {
            // Consumption is already confirmed. Do not misreport failure and
            // invite a second redemption merely because refreshing usage failed.
            return OpenAIResetReceipt(outcome: outcome, limitsRefreshed: false)
        }
    }

    private static func verifyAccount(_ response: [String: JSONValue], expected: String) throws {
        guard response["accountId"] == .string(expected) else { throw OpenAIResetError.accountChanged }
    }

    static func accountID(_ auth: CodexAuth) throws -> String {
        let account = auth.accountId
            ?? JWT.claim(auth.tokens.idToken, key: "https://api.openai.com/auth.chatgpt_account_id", as: String.self)
        guard let account, !account.isEmpty, !auth.tokens.accessToken.isEmpty else {
            throw OpenAIResetError.authorization
        }
        return account
    }

    private static func authenticate(_ auth: CodexAuth, account: String,
                                     rpc: any CodexResetRPC) throws {
        _ = try rpc.request("initialize", params: [
            "clientInfo": .object(["name": .string("ai-taskbar"), "version": .string("1")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ])
        try rpc.notify("initialized")
        // External-token mode cannot rotate the CLI's refresh token: that token
        // is never supplied. The process also uses an isolated temporary home.
        _ = try rpc.request("account/login/start", params: [
            "type": .string("chatgptAuthTokens"),
            "accessToken": .string(auth.tokens.accessToken),
            "chatgptAccountId": .string(account)
        ])
    }

    static func eligibleResetCount(_ response: [String: JSONValue]) -> Int? {
        guard case .object(let credits) = response["rateLimitResetCredits"],
              case .int(let count) = credits["availableCount"], count > 0,
              let available = Int(exactly: count) else { return nil }
        let bucket: [String: JSONValue]
        if case .object(let buckets) = response["rateLimitsByLimitId"],
           case .object(let codex) = buckets["codex"] {
            bucket = codex
        } else if case .object(let single) = response["rateLimits"],
                  single["limitId"] == nil || single["limitId"] == .null
                    || single["limitId"] == .string("codex") {
            bucket = single
        } else { return nil }
        let overThreshold = ["primary", "secondary"].contains { name in
            guard case .object(let window) = bucket[name] else { return false }
            switch window["usedPercent"] {
            case .int(let value): return value > 90
            case .double(let value): return value.isFinite && value > 90
            default: return false
            }
        }
        return overThreshold ? available : nil
    }
}
