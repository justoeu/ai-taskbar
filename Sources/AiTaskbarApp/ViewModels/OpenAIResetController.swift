import Foundation
import Combine
import AiTaskbarCore

/// Lives with the vendor, not the popover: dismissing the menu cannot lose an
/// ambiguous attempt's idempotency key or enable a second in-flight redemption.
@MainActor
final class OpenAIResetController: ObservableObject {
    /// Activity phase of the reset controller for user feedback.
    enum Activity: Equatable, Sendable {
        case idle
        case checking
        case applying
    }

    @Published private(set) var isBusy = false
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var isSuccess = false
    @Published private(set) var offer: OpenAIResetOffer?
    @Published private(set) var pendingAttempt: OpenAIResetOffer?
    @Published private(set) var message: String?
    @Published var isConfirming = false
    private var inFlight = false
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

    /// Synchronously transitions state to checking before the async prepare RPC begins,
    /// providing immediate visual feedback to the user on button click.
    func beginPreparing() {
        guard !isBusy, !inFlight else { return }
        isBusy = true
        activity = .checking
        message = nil
        isSuccess = false
    }

    func prepare(path: URL) async {
        if !isBusy {
            beginPreparing()
        }
        guard isBusy, activity == .checking, !inFlight else { return }
        if let pendingAttempt {
            offer = pendingAttempt
            isConfirming = true
            isBusy = false
            activity = .idle
            return
        }
        inFlight = true
        defer {
            inFlight = false
            isBusy = false
            activity = .idle
        }
        do {
            let prepared = try await prepareAction(path)
            offer = prepared
            if prepared.isRetry { pendingAttempt = prepared }
            isConfirming = true
        } catch {
            message = Self.errorMessage(error)
            isSuccess = false
        }
    }

    func restorePending() async {
        guard !isBusy, !inFlight, pendingAttempt == nil else { return }
        do {
            // Blocking file I/O: a GCD thread, not the cooperative pool.
            let restored = try await OffPool.run { try OpenAIResetJournal().read() }
            guard !isBusy, !inFlight, pendingAttempt == nil else { return }
            pendingAttempt = restored
        } catch {
            message = Self.errorMessage(error)
            isSuccess = false
        }
    }

    func cancelConfirmation() {
        isConfirming = false
        offer = nil
        if !inFlight {
            activity = .idle
            isBusy = false
        }
    }

    /// Synchronously transitions state to applying before the async consume RPC begins,
    /// preventing any modal flash or frozen state after user confirmation.
    func beginConsuming() {
        guard !isBusy, !inFlight, offer != nil else { return }
        isConfirming = false
        isBusy = true
        activity = .applying
        message = nil
        isSuccess = false
    }

    func consume(path: URL) async -> Bool {
        if !isBusy {
            beginConsuming()
        }
        guard isBusy, activity == .applying, !inFlight, let offer else {
            isBusy = false
            activity = .idle
            return false
        }
        let retry = pendingAttempt != nil
        inFlight = true
        defer {
            inFlight = false
            isBusy = false
            activity = .idle
        }
        do {
            let receipt = try await consumeAction(path, offer, retry)
            pendingAttempt = nil
            self.offer = nil
            switch receipt.outcome {
            case .reset, .alreadyRedeemed:
                message = L10n.localizedString(receipt.limitsRefreshed ? "reset_done" : "reset_done_refresh_pending")
                isSuccess = true
            case .nothingToReset:
                message = L10n.localizedString("reset_nothing")
                isSuccess = false
            case .noCredit:
                message = L10n.localizedString("reset_no_credit")
                isSuccess = false
            }
            return true
        } catch {
            if let resetError = error as? OpenAIResetError, resetError == .submissionUncertain {
                pendingAttempt = offer
            }
            message = Self.errorMessage(error)
            isSuccess = false
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
