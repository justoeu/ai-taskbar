import Foundation
import Testing
import AiTaskbarCore
import AiTaskbarProviders
@testable import AiTaskbarApp

@Suite("Z.AI reset controller")
@MainActor
struct ZAIResetControllerTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func snapshot(session: Double) -> VendorSnapshot {
        .zai(ZAISnapshot(
            session: UsageWindow(label: "Session (5h)", utilizationPercent: session, resetsAt: now.addingTimeInterval(10)),
            weekly: UsageWindow(label: "Weekly", utilizationPercent: 21, resetsAt: now.addingTimeInterval(86_400)),
            resetGrants: [ZAIResetGrant(recordID: 9, kind: .weekly, grantType: "GLOBAL",
                                        expiresAt: "2026-12-22 23:59:59")]))
    }

    private func attempt() -> ZAILimitResetAttempt {
        ZAILimitResetAttempt(kind: .weekly, recordID: 9, grantType: "GLOBAL",
                             expiresAt: "2026-12-22 23:59:59", resetsLeft: 3)
    }

    @Test("offers only for a fresh, live Z.AI snapshot above 90%")
    func offers() {
        let fresh = FetchOutcome(snapshot: snapshot(session: 100), fetchedAt: now)
        #expect(ZAIResetController.offers(in: .ok(fresh), now: now).map(\.kind) == [.weekly])
        #expect(ZAIResetController.offers(in: .ok(FetchOutcome(snapshot: snapshot(session: 90), fetchedAt: now)),
                                          now: now).isEmpty)
        #expect(ZAIResetController.offers(in: .idle, now: now).isEmpty)
        #expect(ZAIResetController.offers(in: .ok(FetchOutcome(snapshot: snapshot(session: 100), isStale: true,
                                                                fetchedAt: now)), now: now).isEmpty)
        #expect(ZAIResetController.offers(in: .ok(fresh), now: now.addingTimeInterval(301)).isEmpty)
        // Another vendor's snapshot never yields a Z.AI offer.
        #expect(ZAIResetController.offers(in: .ok(FetchOutcome(snapshot: .anthropic(AnthropicSnapshot()),
                                                                fetchedAt: now)), now: now).isEmpty)
        #expect(ClaudeResetController.offers(in: .ok(fresh), now: now).isEmpty)
    }

    @Test("a confirmed use reports success and clears the attempt")
    func success() async {
        let controller = ZAIResetController(prepare: { _ in attempt() }, consume: { attempt, retry in
            expectFalse(retry)
            return ZAILimitResetReceipt(kind: attempt.kind)
        })
        await controller.prepare(kind: .weekly)
        expectTrue(controller.isConfirming)
        controller.beginConsuming()
        expectTrue(await controller.consume())
        expectTrue(controller.isSuccess)
        expectTrue(controller.attempt == nil)
        #expect(controller.message == L10n.localizedString("zai_reset_done"))
    }

    @Test("only an uncertain use is retried, with the same request id")
    func uncertain() async {
        let first = attempt()
        var calls = 0
        let controller = ZAIResetController(prepare: { _ in first }, consume: { attempt, retry in
            #expect(attempt.id == first.id)
            calls += 1
            if calls == 1 {
                expectFalse(retry)
                throw ZAILimitResetError.submissionUncertain
            }
            expectTrue(retry)
            return ZAILimitResetReceipt(kind: .weekly)
        })
        await controller.prepare(kind: .weekly)
        expectFalse(await controller.consume())
        expectTrue(controller.pendingAttempt?.id == first.id)
        #expect(controller.message == L10n.localizedString("zai_reset_submission_uncertain"))
        await controller.prepare(kind: .fiveHour)
        expectTrue(controller.attempt?.id == first.id)
        expectTrue(await controller.consume())
        expectTrue(controller.pendingAttempt == nil)
    }

    @Test("a refusal drops the attempt: nothing was spent")
    func rejected() async {
        let controller = ZAIResetController(prepare: { _ in attempt() }, consume: { _, _ in
            throw ZAILimitResetError.rejected
        })
        await controller.prepare(kind: .weekly)
        expectFalse(await controller.consume())
        expectTrue(controller.pendingAttempt == nil)
        #expect(controller.message == L10n.localizedString("zai_reset_rejected"))
    }

    @Test("every error and kind has its own text")
    func messages() {
        let errors: [(ZAILimitResetError, String)] = [
            (.noEligibleReset, "zai_reset_unavailable"),
            (.authorization, "zai_reset_auth_required"),
            (.rateLimited, "zai_reset_rate_limited"),
            (.rejected, "zai_reset_rejected"),
            (.submissionUncertain, "zai_reset_submission_uncertain"),
            (.failed, "zai_reset_failed"),
        ]
        for (error, key) in errors {
            #expect(ZAIResetController.errorMessage(error) == L10n.localizedString(key))
            #expect(L10n.localizedString(key) != key)
        }
        #expect(ZAIResetController.errorMessage(URLError(.timedOut)) == L10n.localizedString("zai_reset_failed"))
        #expect(ZAIResetController.kindName(.fiveHour) == L10n.localizedString("zai_reset_kind_five_hour"))
        #expect(ZAIResetController.kindName(.weekly) == L10n.localizedString("zai_reset_kind_weekly"))
        #expect(ZAIResetController.kindName(.weekly) != ZAIResetController.kindName(.fiveHour))
    }

    @Test("the confirmation names the kind, the expiry and the count")
    func confirmation() {
        let presentation = LimitResetControls<ZAILimitResetAttempt, ZAILimitResetReceipt>.Presentation.zai
        let weekly = presentation.confirmMessage("Z.AI", attempt())
        expectTrue(weekly.contains(ZAIResetController.kindName(.weekly)))
        expectTrue(weekly.contains("3"))
        expectTrue(weekly.contains("2026"))
        let fiveHour = presentation.confirmMessage("Z.AI", ZAILimitResetAttempt(
            kind: .fiveHour, recordID: 1, grantType: nil, expiresAt: nil, resetsLeft: 1))
        expectTrue(fiveHour.contains("—"))
        #expect(weekly != fiveHour)
        expectTrue(presentation.info != nil)
        let options = presentation.options(.ok(FetchOutcome(snapshot: snapshot(session: 100), fetchedAt: .now)))
        #expect(options.map(\.kind) == [.weekly])
    }

    @Test("expiry: a plain date is localized, anything else is shown as given")
    func expiry() {
        typealias Controls = LimitResetControls<ZAILimitResetAttempt, ZAILimitResetReceipt>.Presentation
        #expect(Controls.expiry(nil) == "—")
        #expect(Controls.expiry("soon") == "soon")
        let day = Controls.expiry("2026-12-22 23:59:59")
        expectTrue(day.contains("2026"))
        expectTrue(day.contains("22"))
    }
}
