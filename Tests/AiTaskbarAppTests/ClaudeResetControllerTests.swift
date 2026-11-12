import Foundation
import Testing
import AiTaskbarCore
import AiTaskbarProviders
@testable import AiTaskbarApp

@Suite("Claude reset controller")
@MainActor
struct ClaudeResetControllerTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func snapshot(percent: Double) -> VendorSnapshot {
        let grant = ClaudeResetGrant(id: "full-reset-2611", label: "One full limit reset", kind: .weekly,
                                     resetsLeft: 1, clears: ["seven_day"], givesBackWeekly: false)
        return .anthropic(AnthropicSnapshot(
            weekly: UsageWindow(label: "Weekly (7d)", utilizationPercent: percent, resetsAt: now.addingTimeInterval(10)),
            resetGrants: [grant]))
    }

    private func attempt() -> ClaudeLimitResetAttempt {
        ClaudeLimitResetAttempt(kind: .weekly, grantID: "full-reset-2611", grantLabel: "One full limit reset",
                                resetsLeft: 1, accountUUID: "a", organizationUUID: "o")
    }

    @Test("offers only for a fresh, live snapshot above 90%")
    func offers() {
        let fresh = FetchOutcome(snapshot: snapshot(percent: 91), fetchedAt: now)
        #expect(ClaudeResetController.offers(in: .ok(fresh), now: now).map(\.kind) == [.weekly])
        #expect(ClaudeResetController.offers(in: .ok(FetchOutcome(snapshot: snapshot(percent: 90), fetchedAt: now)), now: now).isEmpty)
        #expect(ClaudeResetController.offers(in: .idle, now: now).isEmpty)
        #expect(ClaudeResetController.offers(in: .loading(previous: fresh), now: now).isEmpty)
        #expect(ClaudeResetController.offers(in: .ok(FetchOutcome(snapshot: snapshot(percent: 91), isStale: true,
                                                                   fetchedAt: now)), now: now).isEmpty)
        #expect(ClaudeResetController.offers(in: .ok(FetchOutcome(snapshot: snapshot(percent: 91),
            lastError: FetchError(status: 429, body: "x"), fetchedAt: now)), now: now).isEmpty)
        #expect(ClaudeResetController.offers(in: .ok(fresh), now: now.addingTimeInterval(301)).isEmpty)
        #expect(ClaudeResetController.offers(in: .ok(fresh), now: now.addingTimeInterval(-6)).isEmpty)
        // Past the window's own reset time: awaiting the refresh, not offerable.
        #expect(ClaudeResetController.offers(in: .ok(fresh), now: now.addingTimeInterval(11)).isEmpty)
    }

    @Test("a successful reset clears the attempt and reports success")
    func success() async {
        let controller = ClaudeResetController(prepare: { _ in attempt() }, consume: { _, retry in
            expectFalse(retry)
            return ClaudeLimitResetReceipt(outcome: .reset, resetsLeft: 0)
        })
        await controller.prepare(kind: .weekly)
        expectTrue(controller.isConfirming)
        controller.beginConsuming()
        expectTrue(await controller.consume())
        expectTrue(controller.isSuccess)
        expectTrue(controller.attempt == nil)
        #expect(controller.message == L10n.localizedString("claude_reset_done"))
    }

    @Test("only an uncertain claim is retried, with the same request id")
    func uncertain() async {
        let first = attempt()
        var calls = 0
        let controller = ClaudeResetController(prepare: { _ in first }, consume: { attempt, retry in
            #expect(attempt.id == first.id)
            calls += 1
            if calls == 1 {
                expectFalse(retry)
                throw ClaudeLimitResetError.submissionUncertain
            }
            expectTrue(retry)
            return ClaudeLimitResetReceipt(outcome: .alreadyUsed, resetsLeft: 0)
        })
        await controller.prepare(kind: .weekly)
        expectFalse(await controller.consume())
        expectTrue(controller.pendingAttempt?.id == first.id)
        // A new click resumes the pending attempt instead of preparing another.
        await controller.prepare(kind: .fable)
        expectTrue(controller.attempt?.id == first.id)
        expectTrue(await controller.consume())
        expectTrue(controller.pendingAttempt == nil)
        #expect(controller.message == L10n.localizedString("claude_reset_already_used"))
    }

    @Test("a definitive failure leaves no pending attempt")
    func definitive() async {
        let controller = ClaudeResetController(prepare: { _ in attempt() }, consume: { _, _ in
            throw ClaudeLimitResetError.rateLimited
        })
        await controller.prepare(kind: .weekly)
        expectFalse(await controller.consume())
        expectTrue(controller.pendingAttempt == nil)
        #expect(controller.message == L10n.localizedString("claude_reset_rate_limited"))
    }

    @Test("a failed prepare shows its reason and never confirms")
    func prepareFailure() async {
        let controller = ClaudeResetController(prepare: { _ in throw ClaudeLimitResetError.cliUnavailable },
                                               consume: { _, _ in
            Issue.record("consume must not run")
            return ClaudeLimitResetReceipt(outcome: .reset, resetsLeft: nil)
        })
        await controller.prepare(kind: .fable)
        expectFalse(controller.isConfirming)
        #expect(controller.message == L10n.localizedString("claude_reset_cli_unavailable"))
        expectFalse(await controller.consume())
    }

    @Test("cancel drops the attempt")
    func cancel() async {
        let controller = ClaudeResetController(prepare: { _ in attempt() }, consume: { _, _ in
            ClaudeLimitResetReceipt(outcome: .reset, resetsLeft: nil)
        })
        await controller.prepare(kind: .weekly)
        controller.cancelConfirmation()
        expectFalse(controller.isConfirming)
        expectTrue(controller.attempt == nil)
        expectFalse(controller.isBusy)
    }

    @Test("every server outcome and error has its own message")
    func messages() async {
        let outcomes: [(ClaudeLimitResetOutcome, String, Bool)] = [
            (.notLimited, "claude_reset_not_limited", false),
            (.cooldown, "claude_reset_cooldown", false),
            (.ineligible, "claude_reset_unavailable", false),
            (.unavailable, "claude_reset_unavailable", false),
        ]
        for (outcome, key, success) in outcomes {
            let controller = ClaudeResetController(prepare: { _ in attempt() }, consume: { _, _ in
                ClaudeLimitResetReceipt(outcome: outcome, resetsLeft: nil)
            })
            await controller.prepare(kind: .weekly)
            _ = await controller.consume()
            #expect(controller.message == L10n.localizedString(key))
            #expect(controller.isSuccess == success)
        }
        let errors: [(ClaudeLimitResetError, String)] = [
            (.noEligibleReset, "claude_reset_unavailable"),
            (.accountChanged, "claude_reset_account_changed"),
            (.authorization, "claude_reset_auth_required"),
            (.failed, "claude_reset_failed"),
        ]
        for (error, key) in errors {
            #expect(ClaudeResetController.errorMessage(error) == L10n.localizedString(key))
        }
        for kind in ClaudeResetKind.allCases {
            #expect(ClaudeResetController.kindName(kind) != "claude_reset_kind_\(kind.rawValue)")
        }
    }
}
