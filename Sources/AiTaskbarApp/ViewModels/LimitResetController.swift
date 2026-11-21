import Foundation
import Combine
import AiTaskbarCore
import AiTaskbarProviders

/// An attempt a `LimitResetController` can prepare, confirm and resume.
protocol LimitResetAttempting: Sendable, Equatable {
    associatedtype Kind: Hashable & Sendable
    var kind: Kind { get }
}

extension ClaudeLimitResetAttempt: LimitResetAttempting {}
extension ZAILimitResetAttempt: LimitResetAttempting {}

/// Click → check → in-window confirmation → claim, for a vendor's earned
/// limit resets (Claude, Z.AI). Same rule and boundary as
/// `OpenAIResetController`: lives with the account's view model, so closing
/// the popover cannot lose an uncertain attempt's request id or start a
/// second claim. The pending attempt is kept in memory only; after a
/// relaunch a new click re-reads the vendor first, and the server dedupes by
/// request id.
@MainActor
final class LimitResetController<Attempt: LimitResetAttempting, Receipt: Sendable>: ObservableObject {
    typealias Kind = Attempt.Kind

    enum Activity: Equatable, Sendable {
        case idle
        case checking
        case applying
    }

    /// How a vendor words its answers.
    struct Interpretation {
        /// Message and success flag for a server answer.
        let receipt: (Receipt) -> (message: String, success: Bool)
        let error: (Error) -> String
        /// True only for the error after which the SAME attempt may be retried.
        let isUncertain: (Error) -> Bool
    }

    @Published private(set) var isBusy = false
    @Published private(set) var activity: Activity = .idle
    /// The kind whose button started the current activity.
    @Published private(set) var activeKind: Kind?
    @Published private(set) var isSuccess = false
    @Published private(set) var attempt: Attempt?
    @Published private(set) var pendingAttempt: Attempt?
    @Published private(set) var message: String?
    @Published var isConfirming = false
    private var inFlight = false
    private let prepareAction: (Kind) async throws -> Attempt
    private let consumeAction: (Attempt, Bool) async throws -> Receipt
    private let interpretation: Interpretation

    init(prepare: @escaping (Kind) async throws -> Attempt,
         consume: @escaping (Attempt, Bool) async throws -> Receipt,
         interpretation: Interpretation) {
        prepareAction = prepare
        consumeAction = consume
        self.interpretation = interpretation
    }

    func beginPreparing(kind: Kind) {
        guard !isBusy, !inFlight else { return }
        // A confirmation the view never presented (popover closed while
        // checking) must not swallow this click: `onChange` needs a change.
        isConfirming = false
        isBusy = true
        activity = .checking
        activeKind = kind
        message = nil
        isSuccess = false
    }

    func prepare(kind: Kind) async {
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
            message = interpretation.error(error)
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
            let answer = interpretation.receipt(receipt)
            message = answer.message
            isSuccess = answer.success
            return true
        } catch {
            // Only an uncertain claim keeps its request id; any definitive
            // answer (even on a retry) ends it, so the fresh offers return.
            pendingAttempt = interpretation.isUncertain(error) ? attempt : nil
            message = interpretation.error(error)
            isSuccess = false
            return false
        }
    }
}

/// Same freshness gate for every vendor (and OpenAI's): a live (not stale,
/// error-free) snapshot at most five minutes old.
@MainActor
enum LimitResetFreshness {
    static func liveSnapshot(in state: VendorViewModel.State, now: Date) -> VendorSnapshot? {
        guard case .ok(let outcome) = state, !outcome.isStale, outcome.lastError == nil else { return nil }
        let age = now.timeIntervalSince(outcome.fetchedAt)
        guard age >= -5, age <= 300 else { return nil }
        return outcome.snapshot
    }
}

// MARK: - Claude

typealias ClaudeResetController = LimitResetController<ClaudeLimitResetAttempt, ClaudeLimitResetReceipt>

extension LimitResetController where Attempt == ClaudeLimitResetAttempt, Receipt == ClaudeLimitResetReceipt {
    convenience init(prepare: @escaping (ClaudeResetKind) async throws -> ClaudeLimitResetAttempt,
                     consume: @escaping (ClaudeLimitResetAttempt, Bool) async throws -> ClaudeLimitResetReceipt) {
        self.init(prepare: prepare, consume: consume, interpretation: Interpretation(
            receipt: { receipt in
                switch receipt.outcome {
                case .reset: return (L10n.localizedString("claude_reset_done"), true)
                case .alreadyUsed: return (L10n.localizedString("claude_reset_already_used"), true)
                case .notLimited: return (L10n.localizedString("claude_reset_not_limited"), false)
                case .cooldown: return (L10n.localizedString("claude_reset_cooldown"), false)
                case .ineligible, .unavailable: return (L10n.localizedString("claude_reset_unavailable"), false)
                }
            },
            error: { Self.errorMessage($0) },
            isUncertain: { $0 as? ClaudeLimitResetError == .submissionUncertain }))
    }

    convenience init(service: ClaudeLimitResetService) {
        self.init(prepare: { try await service.prepare(kind: $0) },
                  consume: { try await service.consume($0, retry: $1) })
    }

    /// The freshness gate, then `AnthropicSnapshot.limitResetOffers`.
    static func offers(in state: VendorViewModel.State, now: Date = .now) -> [ClaudeResetOffer] {
        guard case .anthropic(let snapshot) = LimitResetFreshness.liveSnapshot(in: state, now: now) else { return [] }
        return snapshot.limitResetOffers(now: now)
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

// MARK: - Z.AI

typealias ZAIResetController = LimitResetController<ZAILimitResetAttempt, ZAILimitResetReceipt>

extension LimitResetController where Attempt == ZAILimitResetAttempt, Receipt == ZAILimitResetReceipt {
    convenience init(prepare: @escaping (ZAIResetKind) async throws -> ZAILimitResetAttempt,
                     consume: @escaping (ZAILimitResetAttempt, Bool) async throws -> ZAILimitResetReceipt) {
        self.init(prepare: prepare, consume: consume, interpretation: Interpretation(
            receipt: { _ in (L10n.localizedString("zai_reset_done"), true) },
            error: { Self.errorMessage($0) },
            isUncertain: { $0 as? ZAILimitResetError == .submissionUncertain }))
    }

    convenience init(service: ZAILimitResetService) {
        self.init(prepare: { try await service.prepare(kind: $0) },
                  consume: { try await service.consume($0, retry: $1) })
    }

    /// The freshness gate, then `ZAISnapshot.limitResetOffers`.
    static func offers(in state: VendorViewModel.State, now: Date = .now) -> [ZAIResetOffer] {
        guard case .zai(let snapshot) = LimitResetFreshness.liveSnapshot(in: state, now: now) else { return [] }
        return snapshot.limitResetOffers(now: now)
    }

    static func errorMessage(_ error: Error) -> String {
        switch error as? ZAILimitResetError {
        case .noEligibleReset: return L10n.localizedString("zai_reset_unavailable")
        case .authorization: return L10n.localizedString("zai_reset_auth_required")
        case .rateLimited: return L10n.localizedString("zai_reset_rate_limited")
        case .rejected: return L10n.localizedString("zai_reset_rejected")
        case .submissionUncertain: return L10n.localizedString("zai_reset_submission_uncertain")
        default: return L10n.localizedString("zai_reset_failed")
        }
    }

    static func kindName(_ kind: ZAIResetKind) -> String {
        switch kind {
        case .fiveHour: return L10n.localizedString("zai_reset_kind_five_hour")
        case .weekly: return L10n.localizedString("zai_reset_kind_weekly")
        }
    }
}
