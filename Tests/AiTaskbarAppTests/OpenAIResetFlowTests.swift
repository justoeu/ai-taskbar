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
