import Foundation
import AiTaskbarCore

/// Notices a Claude Code account added or logged out after launch
/// (SDD-claude-multi-account §6.6). Providers are built once at launch, like
/// the rest of the config, so a change raises the existing "relaunch to
/// apply" banner instead of hot-swapping cards.
@MainActor
public final class ClaudeAccountWatcher: ObservableObject {
    @Published public private(set) var accountsChanged = false

    private var baseline: Set<String>
    /// The set the check that raised the banner saw; dismissing adopts it
    /// synchronously, so a check started right after cannot compare against
    /// the old reference and raise the same banner again.
    private var lastSeen: Set<String>?
    private let discover: @Sendable () -> [ClaudeAccount]
    private var inFlight: Task<Void, Never>?

    public init(launchAccounts: [ClaudeAccount], discover: @escaping @Sendable () -> [ClaudeAccount]) {
        self.baseline = Self.keys(launchAccounts)
        self.discover = discover
    }

    /// Re-runs discovery off the main actor (it lists the home folder, reads
    /// config files and asks the Keychain for attributes). One at a time; a
    /// pending banner needs no second look.
    public func check() {
        guard inFlight == nil, !accountsChanged else { return }
        let discover = self.discover
        inFlight = Task { [weak self] in
            let keys = await Task.detached(priority: .utility) { Self.keys(discover()) }.value
            guard let self else { return }
            self.inFlight = nil
            if keys != self.baseline {
                self.lastSeen = keys
                self.accountsChanged = true
            }
        }
    }

    /// Internal so tests can await a `check()`.
    var pendingCheck: Task<Void, Never>? { inFlight }

    /// The user dismissed the banner: the current set becomes the reference,
    /// so the same change does not raise it again.
    public func dismiss() {
        guard accountsChanged else { return }
        accountsChanged = false
        if let lastSeen { baseline = lastSeen }
        lastSeen = nil
    }

    nonisolated static func keys(_ accounts: [ClaudeAccount]) -> Set<String> {
        Set(accounts.map(\.instanceKey.storageKey))
    }
}
