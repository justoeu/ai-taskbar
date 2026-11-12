import Foundation
import Combine
import AiTaskbarCore
import AiTaskbarProviders

/// Claude counterpart of `OpenAIResetController`, with the same rule and the
/// same boundary: lives with the account's view model, so closing the popover
/// cannot lose an uncertain attempt's `request_id` or start a second claim.
/// The pending attempt is kept in memory only; after a relaunch a new click
/// re-reads the grants first, and the server dedupes by `request_id`.
@MainActor
final class ClaudeResetController: ObservableObject {
    enum Activity: Equatable, Sendable {
        case idle
        case checking
        case applying
    }

    @Published private(set) var isBusy = false
    @Published private(set) var activity: Activity = .idle
    /// The kind whose button started the current activity.
    @Published private(set) var activeKind: ClaudeResetKind?
    @Published private(set) var isSuccess = false
    @Published private(set) var attempt: ClaudeLimitResetAttempt?
    @Published private(set) var pendingAttempt: ClaudeLimitResetAttempt?
    @Published private(set) var message: String?
    @Published var isConfirming = false
    private var inFlight = false
    private let prepareAction: (ClaudeResetKind) async throws -> ClaudeLimitResetAttempt
    private let consumeAction: (ClaudeLimitResetAttempt, Bool) async throws -> ClaudeLimitResetReceipt

    init(prepare: @escaping (ClaudeResetKind) async throws -> ClaudeLimitResetAttempt,
         consume: @escaping (ClaudeLimitResetAttempt, Bool) async throws -> ClaudeLimitResetReceipt) {
        prepareAction = prepare
        consumeAction = consume
    }

    convenience init(service: ClaudeLimitResetService) {
        self.init(prepare: { try await service.prepare(kind: $0) },
                  consume: { try await service.consume($0, retry: $1) })
    }

    /// Same freshness gate as OpenAI: a live (not stale, error-free) snapshot
    /// at most five minutes old, then `AnthropicSnapshot.limitResetOffers`.
    static func offers(in state: VendorViewModel.State, now: Date = .now) -> [ClaudeResetOffer] {
        guard case .ok(let outcome) = state, !outcome.isStale, outcome.lastError == nil,
              case .anthropic(let snapshot) = outcome.snapshot else { return [] }
        let age = now.timeIntervalSince(outcome.fetchedAt)
        guard age >= -5, age <= 300 else { return [] }
        return snapshot.limitResetOffers(now: now)
    }

    func beginPreparing(kind: ClaudeResetKind) {
        guard !isBusy, !inFlight else { return }
        isBusy = true
        activity = .checking
        activeKind = kind
        message = nil
        isSuccess = false
    }

    func prepare(kind: ClaudeResetKind) async {
        if !isBusy { beginPreparing(kind: kind) }
        guard isBusy, activity == .checking, !inFlight else { return }
        if let pendingAttempt {
            // An uncertain attempt is resumed, never replaced by a new one.
            attempt = pendingAttempt
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
            attempt = try await prepareAction(kind)
            isConfirming = true
        } catch {
            message = Self.errorMessage(error)
            isSuccess = false
        }
    }

    func cancelConfirmation() {
        isConfirming = false
        attempt = nil
        if !inFlight {
            activity = .idle
            isBusy = false
            activeKind = nil
        }
    }

    func beginConsuming() {
        guard !isBusy, !inFlight, attempt != nil else { return }
        isConfirming = false
        isBusy = true
        activity = .applying
        activeKind = attempt?.kind
        message = nil
        isSuccess = false
    }

    /// True when the server answered, so the card should refresh.
    func consume() async -> Bool {
        if !isBusy { beginConsuming() }
        guard isBusy, activity == .applying, !inFlight, let attempt else {
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
            let receipt = try await consumeAction(attempt, retry)
            pendingAttempt = nil
            self.attempt = nil
            switch receipt.outcome {
            case .reset:
                message = L10n.localizedString("claude_reset_done")
                isSuccess = true
            case .alreadyUsed:
                message = L10n.localizedString("claude_reset_already_used")
                isSuccess = true
            case .notLimited:
                message = L10n.localizedString("claude_reset_not_limited")
                isSuccess = false
            case .cooldown:
                message = L10n.localizedString("claude_reset_cooldown")
                isSuccess = false
            case .ineligible, .unavailable:
                message = L10n.localizedString("claude_reset_unavailable")
                isSuccess = false
            }
            return true
        } catch {
            if error as? ClaudeLimitResetError == .submissionUncertain {
                pendingAttempt = attempt
            }
            message = Self.errorMessage(error)
            isSuccess = false
            return false
        }
    }

    static func errorMessage(_ error: Error) -> String {
        switch error as? ClaudeLimitResetError {
        case .cliUnavailable: return L10n.localizedString("claude_reset_cli_unavailable")
        case .noEligibleReset: return L10n.localizedString("claude_reset_unavailable")
        case .accountChanged: return L10n.localizedString("claude_reset_account_changed")
        case .authorization: return L10n.localizedString("claude_reset_auth_required")
        case .rateLimited: return L10n.localizedString("claude_reset_rate_limited")
        case .submissionUncertain: return L10n.localizedString("claude_reset_submission_uncertain")
        default: return L10n.localizedString("claude_reset_failed")
        }
    }

    static func kindName(_ kind: ClaudeResetKind) -> String {
        L10n.localizedString("claude_reset_kind_\(kind.rawValue)")
    }
}
