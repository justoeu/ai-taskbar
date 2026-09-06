import Foundation
import Combine
import AiTaskbarCore

/// Lives with the vendor, not the popover: dismissing the menu cannot lose an
/// ambiguous attempt's idempotency key or enable a second in-flight redemption.
@MainActor
final class OpenAIResetController: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var offer: OpenAIResetOffer?
    @Published private(set) var pendingAttempt: OpenAIResetOffer?
    @Published private(set) var message: String?
    @Published var isConfirming = false
    private let prepareAction: (URL) async throws -> OpenAIResetOffer
    private let consumeAction: (URL, OpenAIResetOffer, Bool) async throws -> OpenAIResetReceipt

    init(prepare: @escaping (URL) async throws -> OpenAIResetOffer = { try await OpenAIResetService.prepare(path: $0) },
         consume: @escaping (URL, OpenAIResetOffer, Bool) async throws -> OpenAIResetReceipt = {
             try await OpenAIResetService.consume(path: $0, offer: $1, retry: $2)
         }) {
        prepareAction = prepare
        consumeAction = consume
    }

    static func canOffer(in state: VendorViewModel.State, now: Date = .now) -> Bool {
        guard case .ok(let outcome) = state, !outcome.isStale, outcome.lastError == nil,
              case .openai(let snapshot) = outcome.snapshot,
              snapshot.canOfferRateLimitReset else { return false }
        let age = now.timeIntervalSince(outcome.fetchedAt)
        guard age >= -5, age <= 300 else { return false }
        return [snapshot.primary, snapshot.secondary].compactMap { $0 }.contains {
            $0.utilizationPercent.isFinite && $0.utilizationPercent > 90 && !$0.isAwaitingReset(now: now)
        }
    }

    func prepare(path: URL) async {
        guard !isBusy else { return }
        if let pendingAttempt {
            offer = pendingAttempt
            isConfirming = true
            return
        }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            let prepared = try await prepareAction(path)
            offer = prepared
            if prepared.isRetry { pendingAttempt = prepared }
            isConfirming = true
        } catch { message = Self.errorMessage(error) }
    }

    func restorePending() async {
        guard !isBusy, pendingAttempt == nil else { return }
        do {
            let restored = try await Task.detached { try OpenAIResetJournal().read() }.value
            guard !isBusy, pendingAttempt == nil else { return }
            pendingAttempt = restored
        } catch { message = Self.errorMessage(error) }
    }

    func cancelConfirmation() {
        isConfirming = false
        offer = nil
    }

    func consume(path: URL) async -> Bool {
        guard !isBusy, let offer else { return false }
        let retry = pendingAttempt != nil
        isConfirming = false
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            let receipt = try await consumeAction(path, offer, retry)
            pendingAttempt = nil
            self.offer = nil
            switch receipt.outcome {
            case .reset, .alreadyRedeemed:
                message = L10n.localizedString(receipt.limitsRefreshed ? "reset_done" : "reset_done_refresh_pending")
            case .nothingToReset: message = L10n.localizedString("reset_nothing")
            case .noCredit: message = L10n.localizedString("reset_no_credit")
            }
            return true
        } catch {
            if let resetError = error as? OpenAIResetError, resetError == .submissionUncertain {
                pendingAttempt = offer
            }
            message = Self.errorMessage(error)
            return false
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        switch error as? OpenAIResetError {
        case .unavailable, .methodNotFound, .consumeUnsupported: return L10n.localizedString("reset_cli_unavailable")
        case .noEligibleReset: return L10n.localizedString("reset_unavailable")
        case .accountChanged: return L10n.localizedString("reset_account_changed")
        case .authorization: return L10n.localizedString("reset_auth_required")
        case .submissionUncertain: return L10n.localizedString("reset_submission_uncertain")
        case .attemptInProgress: return L10n.localizedString("reset_attempt_in_progress")
        default: return L10n.localizedString("reset_failed")
        }
    }
}
