import Foundation
import Testing
import AiTaskbarCore
@testable import AiTaskbarApp

@Suite("OpenAI reset submission boundary")
@MainActor
struct OpenAIResetControllerTests {
    @Test("action excludes stale, loading, old and already-reset snapshots")
    func eligibility_states() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = VendorSnapshot.openai(OpenAISnapshot(primary: UsageWindow(label: "Session", utilizationPercent: 91,
            resetsAt: now.addingTimeInterval(10)), availableResetCount: 1))
        let fresh = FetchOutcome(snapshot: snapshot, fetchedAt: now)
        expectTrue(OpenAIResetController.canOffer(in: .ok(fresh), now: now))
        expectFalse(OpenAIResetController.canOffer(in: .idle, now: now))
        expectFalse(OpenAIResetController.canOffer(in: .loading(previous: fresh), now: now))
        expectFalse(OpenAIResetController.canOffer(in: .failed(error: .credentials("test"), fallback: fresh), now: now))
        expectFalse(OpenAIResetController.canOffer(in: .ok(FetchOutcome(snapshot: snapshot, isStale: true, fetchedAt: now)), now: now))
        expectFalse(OpenAIResetController.canOffer(in: .ok(FetchOutcome(snapshot: snapshot,
            lastError: FetchError(status: 429, body: "test"), fetchedAt: now)), now: now))
        expectFalse(OpenAIResetController.canOffer(in: .ok(fresh), now: now.addingTimeInterval(301)))
        expectFalse(OpenAIResetController.canOffer(in: .ok(fresh), now: now.addingTimeInterval(11)))
        expectFalse(OpenAIResetController.canOffer(in: .ok(fresh), now: now.addingTimeInterval(-6)))
    }

    @Test("pre-submit failures never bypass eligibility on a subsequent attempt")
    func pre_submit_failure() async {
        let offer = OpenAIResetOffer(accountID: "A", accountLabel: "A", availableCount: 1)
        let controller = OpenAIResetController(prepare: { _ in offer }, consume: { _, _, retry in
            expectFalse(retry)
            throw OpenAIResetError.unavailable
        })
        let path = URL(fileURLWithPath: "/unused-test-auth")
        await controller.prepare(path: path)
        expectFalse(await controller.consume(path: path))
        expectTrue(controller.pendingAttempt == nil)
        await controller.prepare(path: path)
        expectFalse(await controller.consume(path: path))
        expectTrue(controller.pendingAttempt == nil)
    }

    @Test("only an uncertain submission is retried, using its original key")
    func uncertain_submit() async {
        let offer = OpenAIResetOffer(accountID: "A", accountLabel: "A", availableCount: 1)
        var calls = 0
        let controller = OpenAIResetController(prepare: { _ in offer }, consume: { _, attempt, retry in
            #expect(attempt.id == offer.id)
            calls += 1
            if calls == 1 {
                expectFalse(retry)
                throw OpenAIResetError.submissionUncertain
            }
            expectTrue(retry)
            return OpenAIResetReceipt(outcome: .alreadyRedeemed, limitsRefreshed: true)
        })
        let path = URL(fileURLWithPath: "/unused-test-auth")
        await controller.prepare(path: path)
        expectFalse(await controller.consume(path: path))
        expectTrue(controller.pendingAttempt?.id == offer.id)
        controller.cancelConfirmation()
        await controller.prepare(path: path)
        expectTrue(await controller.consume(path: path))
        expectTrue(controller.pendingAttempt == nil)
        #expect(calls == 2)
    }
}
