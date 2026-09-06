import Foundation
import Testing
import AiTaskbarCore
import AiTaskbarTestSupport
@testable import AiTaskbarApp

private final class ResetRPCStub: CodexResetRPC {
    var calls: [(String, [String: JSONValue])] = []
    var replies: [[String: JSONValue]]
    var rejectedMethod: String?
    init(_ replies: [[String: JSONValue]]) { self.replies = replies }
    func request(_ method: String, params: [String: JSONValue]) throws -> [String: JSONValue] {
        calls.append((method, params))
        if method == rejectedMethod { throw OpenAIResetError.methodNotFound }
        guard !replies.isEmpty else { throw OpenAIResetError.protocolFailure }
        return replies.removeFirst()
    }
    func notify(_ method: String) throws { calls.append((method, [:])) }
}

@Suite("OpenAI reset protocol safety")
struct OpenAIResetFlowTests {
    private let auth = CodexAuth(tokens: .init(accessToken: "access-only",
        refreshToken: "NEVER-SEND", idToken: "id"), accountId: "account-A")
    private let limits: [String: JSONValue] = [
        "accountId": .string("account-A"),
        "rateLimitResetCredits": .object(["availableCount": .int(2)]),
        "rateLimits": .object(["limitId": .string("codex"),
            "primary": .object(["usedPercent": .int(91)])])
    ]

    @Test("prepare verifies availability but never consumes or shares refresh tokens")
    func prepare_is_read_only() throws {
        let rpc = ResetRPCStub([[:], [:], limits])
        let offer = try OpenAIResetProtocol.prepare(auth: auth, rpc: rpc)
        #expect(offer.accountID == "account-A")
        #expect(offer.availableCount == 2)
        #expect(rpc.calls.map(\.0) == ["initialize", "initialized", "account/login/start", "account/rateLimits/read"])
        let login = rpc.calls[2].1
        expectTrue(login["type"] == .string("chatgptAuthTokens"))
        expectTrue(login["accessToken"] == .string("access-only"))
        expectTrue(login["refreshToken"] == nil)
        expectTrue(login["idToken"] == nil)
    }

    @Test("native CLI auth file reaches read-only reset preparation without a new login")
    func native_file_prepare() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Paths.ensureDir(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        let data = Data(#"{"tokens":{"access_token":"access-only","refresh_token":"NEVER-SEND","id_token":"id","account_id":"account-A"}}"#.utf8)
        try AtomicFileWrite.write(data, to: file, permissions: 0o600)
        let rpc = ResetRPCStub([[:], [:], limits])
        let offer = try OpenAIResetProtocol.prepare(auth: FileCredentialReader(path: file).read(), rpc: rpc)
        #expect(offer.accountID == "account-A")
        #expect(offer.availableCount == 2)
        #expect(rpc.calls.map(\.0) == ["initialize", "initialized", "account/login/start", "account/rateLimits/read"])
        expectTrue(rpc.calls[2].1 == ["type": .string("chatgptAuthTokens"),
                                    "accessToken": .string("access-only"),
                                    "chatgptAccountId": .string("account-A")])
        #expect(try Data(contentsOf: file) == data)
    }

    private func tokenAuth(_ payload: String, account: String? = nil) -> CodexAuth {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return CodexAuth(tokens: .init(accessToken: "access-only", refreshToken: "NEVER-SEND",
                                      idToken: "e30.\(encoded).signature"), accountId: account)
    }

    @Test("nested JWT account claim and legacy literal claim both support preparation")
    func jwt_account_fallback() throws {
        for payload in [
            #"{"https://api.openai.com/auth":{"chatgpt_account_id":"account-A"}}"#,
            #"{"https://api.openai.com/auth.chatgpt_account_id":"account-A"}"#
        ] {
            let rpc = ResetRPCStub([[:], [:], limits])
            #expect(try OpenAIResetProtocol.prepare(auth: tokenAuth(payload), rpc: rpc).accountID == "account-A")
        }
    }

    @Test("explicit account beats JWT fallback and nested JWT beats legacy literal")
    func account_source_precedence() throws {
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"account-A"},"https://api.openai.com/auth.chatgpt_account_id":"old-account"}"#
        #expect(try OpenAIResetProtocol.accountID(tokenAuth(payload)) == "account-A")
        #expect(try OpenAIResetProtocol.accountID(tokenAuth(payload, account: "selected-account")) == "selected-account")
    }

    @Test("missing or malformed JWT account fails before any RPC")
    func invalid_account_claims() {
        for payload in ["{}", #"{"https://api.openai.com/auth":{"chatgpt_account_id":42}}"#,
                        #"{"https://api.openai.com/auth":{"chatgpt_account_id":""}}"#,
                        #"{"https://api.openai.com/auth.chatgpt_account_id":42}"#] {
            let rpc = ResetRPCStub([])
            #expect(throws: OpenAIResetError.authorization) {
                try OpenAIResetProtocol.prepare(auth: tokenAuth(payload), rpc: rpc)
            }
            #expect(rpc.calls.count == 0)
        }
    }

    @Test("explicitly empty selected account cannot fall back to a different identity")
    func empty_selected_account_fails_closed() {
        let rpc = ResetRPCStub([])
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"account-A"}}"#
        #expect(throws: OpenAIResetError.authorization) {
            try OpenAIResetProtocol.prepare(auth: tokenAuth(payload, account: ""), rpc: rpc)
        }
        #expect(rpc.calls.count == 0)
    }

    @Test("consumption reuses the supplied attempt key and refreshes limits")
    func consume_and_refresh() throws {
        let offer = OpenAIResetOffer(accountID: "account-A", accountLabel: "A", availableCount: 2)
        for outcome in ["reset", "alreadyRedeemed", "nothingToReset", "noCredit"] {
            let rpc = ResetRPCStub([[:], [:], limits, ["outcome": .string(outcome)], limits])
            let result = try OpenAIResetProtocol.consume(auth: auth, offer: offer, retry: false, rpc: rpc)
            #expect(result.outcome.rawValue == outcome)
            #expect(rpc.calls[4].0 == "account/rateLimitResetCredit/consume")
            expectTrue(rpc.calls[4].1["idempotencyKey"] == .string(offer.id.uuidString))
            expectTrue(rpc.calls.last?.0 == "account/rateLimits/read")
        }
    }

    @Test("account switch and unavailable credit fail closed before consumption")
    func preconditions() throws {
        let other = OpenAIResetOffer(accountID: "account-B", accountLabel: "B", availableCount: 2)
        let rpc = ResetRPCStub([])
        #expect(throws: OpenAIResetError.accountChanged) {
            try OpenAIResetProtocol.consume(auth: auth, offer: other, retry: false, rpc: rpc)
        }
        #expect(rpc.calls.count == 0)
        let empty = ResetRPCStub([[:], [:], ["accountId": .string("account-A")]])
        #expect(throws: OpenAIResetError.noEligibleReset) {
            try OpenAIResetProtocol.prepare(auth: auth, rpc: empty)
        }
        #expect(empty.calls.count == 4)
    }

    @Test("retry keeps the original key even when a prior reset cleared the windows")
    func ambiguous_retry() throws {
        let offer = OpenAIResetOffer(accountID: "account-A", accountLabel: "A", availableCount: 2)
        let rpc = ResetRPCStub([[:], [:], ["accountId": .string("account-A")], ["outcome": .string("alreadyRedeemed")], [:]])
        let result = try OpenAIResetProtocol.consume(auth: auth, offer: offer, retry: true, rpc: rpc)
        #expect(result.outcome == .alreadyRedeemed)
        expectTrue(rpc.calls[4].1["idempotencyKey"] == .string(offer.id.uuidString))
    }

    @Test("server identity is required even on retry")
    func server_identity() {
        let offer = OpenAIResetOffer(accountID: "account-A", accountLabel: "A", availableCount: 2)
        for account: JSONValue in [.null, .string("account-B")] {
            for retry in [false, true] {
                let rpc = ResetRPCStub([[:], [:], ["accountId": account]])
                #expect(throws: OpenAIResetError.accountChanged) {
                    try OpenAIResetProtocol.consume(auth: auth, offer: offer, retry: retry, rpc: rpc)
                }
                #expect(rpc.calls.count == 4)
            }
        }
    }

    @Test("explicit method-not-found rejection is not an ambiguous redemption")
    func unsupported_consume() {
        let rpc = ResetRPCStub([[:], [:], limits])
        rpc.rejectedMethod = "account/rateLimitResetCredit/consume"
        let offer = OpenAIResetOffer(accountID: "account-A", accountLabel: "A", availableCount: 2)
        #expect(throws: OpenAIResetError.consumeUnsupported) {
            try OpenAIResetProtocol.consume(auth: auth, offer: offer, retry: false, rpc: rpc)
        }
    }

    @Test("dispatch boundary and a confirmed reset with failed refresh remain distinct")
    func submission_boundary() throws {
        let offer = OpenAIResetOffer(accountID: "account-A", accountLabel: "A", availableCount: 2)
        var dispatched = 0
        let preflight = ResetRPCStub([[:], [:], ["accountId": .string("account-A")]])
        #expect(throws: OpenAIResetError.noEligibleReset) {
            try OpenAIResetProtocol.consume(auth: auth, offer: offer, retry: false, rpc: preflight,
                                           beforeDispatch: { dispatched += 1 })
        }
        #expect(dispatched == 0)
        let lost = ResetRPCStub([[:], [:], limits])
        #expect(throws: OpenAIResetError.submissionUncertain) {
            try OpenAIResetProtocol.consume(auth: auth, offer: offer, retry: false, rpc: lost,
                                           beforeDispatch: { dispatched += 1 })
        }
        #expect(dispatched == 1)
        let confirmed = ResetRPCStub([[:], [:], limits, ["outcome": .string("reset")]])
        let receipt = try OpenAIResetProtocol.consume(auth: auth, offer: offer, retry: false, rpc: confirmed)
        #expect(receipt.outcome == .reset)
        expectFalse(receipt.limitsRefreshed)
    }
}
