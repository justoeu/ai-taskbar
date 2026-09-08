import Foundation
import Security
import os

/// Reads the exact Claude Code credential selected by account and persistent
/// Keychain reference. The recursive gate orders read/authorize/write/cache
/// mutations before the process-wide prompt gate; no token crosses accounts.
public final class KeychainCredentialReader: AnthropicCredentialReading, @unchecked Sendable {
    public let service: String
    public let preferredAccount: String?
    private let searchList: [SecKeychain]?
    private let credentialMutationGate = NSRecursiveLock()
    private var target: KeychainAccessAuthorizer.TargetIdentity?
    private var pending: (identity: KeychainAccessAuthorizer.TargetIdentity?,
                          credentials: AnthropicCredentials)?
    private var lastKnownGood: AnthropicCredentials?
    /// Read-only escape hatch for an ACL-blocked direct read: the same
    /// `/usr/bin/security` path the Claude Code CLI uses. nil disables it.
    private let fallback: SecurityToolCredentialReader?
    private let secItemRead: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    private var didLogFallback = false
    public static let memoryCacheBuffer: TimeInterval = 300

    public convenience init(service: String = "Claude Code-credentials",
                            preferredAccount: String? = nil) {
        self.init(service: service, preferredAccount: preferredAccount, searchList: nil,
                  fallback: SecurityToolCredentialReader())
    }

    /// Explicit search list isolates integration tests from the user's login Keychain.
    /// `secItemRead` is a test seam for forcing ACL fast-fail statuses.
    internal init(service: String, preferredAccount: String? = nil,
                  searchList: [SecKeychain]?,
                  fallback: SecurityToolCredentialReader? = nil,
                  secItemRead: @escaping @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
                      = { SecItemCopyMatching($0, $1) }) {
        self.service = service
        self.preferredAccount = preferredAccount
        self.searchList = searchList
        self.fallback = fallback
        self.secItemRead = secItemRead
    }

    public func read() throws -> AnthropicCredentials {
        credentialMutationGate.lock()
        defer { credentialMutationGate.unlock() }
        if let lastKnownGood, !lastKnownGood.isExpired(buffer: Self.memoryCacheBuffer) {
            return lastKnownGood
        }
        let disk = Result { try readCurrentItem() }
        let matchingPending = pending.flatMap { $0.identity == target ? $0.credentials : nil }
        let diskCredentials: AnthropicCredentials?
        switch disk {
        case .success(let value): diskCredentials = value
        case .failure: diskCredentials = nil
        }
        guard let verdict = CredentialReconciliation.pick(disk: diskCredentials,
                                                           pending: matchingPending) else {
            return try disk.get()
        }
        if verdict.dropPending { pending = nil }
        lastKnownGood = verdict.credentials
        return verdict.credentials
    }

    public func authorizePersistently() throws -> KeychainAccessAuthorizer.Outcome {
        try authorizePersistently(using: { service, account in
            try KeychainAccessAuthorizer.authorize(
                service: service, searchList: self.searchList, account: account,
                teamID: CodeSignatureInfo.currentTeamID(),
                didAuthorize: { self.bindTarget($0) })
        })
    }

    internal func authorizePersistently(
        using authorize: (String, String?) throws -> KeychainAccessAuthorizer.Outcome,
        beforePendingPersistence: () -> Void = {}
    ) throws -> KeychainAccessAuthorizer.Outcome {
        credentialMutationGate.lock()
        defer { credentialMutationGate.unlock() }
        let outcome = try authorize(service, preferredAccount ?? target?.account)
        guard outcome == .authorized else { return outcome }
        lastKnownGood = nil
        let reconciled = try read()
        if pending != nil {
            beforePendingPersistence()
            try writeBack(reconciled)
        }
        return .authorized
    }

    /// A grant is emitted only after the authorizer's same-item silent probe.
    /// Changing/recreating the item invalidates EVERY associated cached token.
    internal func bindTarget(_ identity: KeychainAccessAuthorizer.TargetIdentity) {
        credentialMutationGate.lock()
        defer { credentialMutationGate.unlock() }
        if target != identity {
            pending = nil
            lastKnownGood = nil
        }
        target = identity
    }

    private func resolvedTarget() throws -> KeychainAccessAuthorizer.TargetIdentity {
        if let target { return target }
        let identity = try KeychainAccessAuthorizer.resolveIdentity(
            service: service, account: preferredAccount, searchList: searchList)
        bindTarget(identity)
        return identity
    }

    private func readCurrentItem() throws -> AnthropicCredentials {
        if target == nil {
            let identities = try KeychainAccessAuthorizer.candidateIdentities(service: service, searchList: searchList)
                .filter { preferredAccount == nil || $0.account == preferredAccount }
            if preferredAccount != nil && identities.count > 1 {
                throw AppError.credentials("Multiple Keychain items match the configured account. Resolve duplicate credentials before continuing.")
            }
            var readable: [KeychainItem] = []
            var failure: Error = Self.errorFor(status: errSecItemNotFound, op: "locate credential")
            for identity in identities {
                do {
                    readable.append(KeychainItem(account: identity.account ?? "",
                                                 data: try readData(identity), identity: identity))
                } catch {
                    // A readable legacy sibling must not hide the Authorize
                    // banner for an inaccessible, potentially newer credential.
                    if let appError = error as? AppError, appError.isKeychainACLBlocked { throw error }
                    failure = error
                }
            }
            guard !readable.isEmpty else { throw failure }
            let selected = select(from: readable)
            guard let identity = selected.identity else { throw failure }
            bindTarget(identity)
            return try decode(selected.data)
        }
        return try decode(readData(resolvedTarget()))
    }

    private func readData(_ identity: KeychainAccessAuthorizer.TargetIdentity) throws -> Data {
        var result: CFTypeRef?
        var query = exactQuery(identity)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let read = secItemRead
        let status = KeychainPromptSuppressor.withPromptsSuppressed {
            read(query as CFDictionary, &result)
        }
        // Never carry a pending token onto a replacement with the same account.
        // Let the next scheduled read resolve the replacement from scratch.
        if (status == errSecItemNotFound || status == errSecInvalidItemRef), target == identity {
            target = nil
            pending = nil
            lastKnownGood = nil
        }
        if Self.isACLBlockedStatus(status), let data = readViaSecurityTool(identity, directStatus: status) {
            return data
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw Self.errorFor(status: status, op: "read selected credential")
        }
        return data
    }

    /// Same item, read by `/usr/bin/security` instead of this binary. Returns
    /// nil when the fallback is disabled or fails, so the caller surfaces the
    /// original ACL error and the Authorize banner stays reachable.
    private func readViaSecurityTool(_ identity: KeychainAccessAuthorizer.TargetIdentity,
                                     directStatus: OSStatus) -> Data? {
        guard let fallback else { return nil }
        do {
            let data = try fallback.read(service: service, account: identity.account)
            if !didLogFallback {
                didLogFallback = true
                AppLog.keychain.notice("Direct Keychain read fast-failed (OSStatus \(directStatus, privacy: .public)); credential read through /usr/bin/security, the path the Claude Code CLI itself uses. Authorize in the Claude card restores direct access.")
            }
            return data
        } catch SecurityToolCredentialReader.Failure.coolingDown {
            // The failure that started the cooldown was already logged.
            return nil
        } catch {
            AppLog.keychain.error("security tool fallback unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func decode(_ data: Data) throws -> AnthropicCredentials {
        do {
            return try SharedCoders.decoder.decode(AnthropicCredentialsFile.self, from: data).claudeAiOauth
        } catch {
            throw AppError.schema("Invalid Claude Code credential JSON")
        }
    }

    private func exactQuery(_ identity: KeychainAccessAuthorizer.TargetIdentity) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identity.account ?? "",
            kSecMatchItemList as String: [identity.persistentRef] as CFArray,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let searchList { query[kSecMatchSearchList as String] = searchList }
        return query
    }

    public func writeBack(_ updated: AnthropicCredentials) throws {
        credentialMutationGate.lock()
        defer { credentialMutationGate.unlock() }
        let identity = try resolvedTarget()
        let data = try SharedCoders.encoder.encode(AnthropicCredentialsFile(claudeAiOauth: updated))
        let status = KeychainPromptSuppressor.withPromptsSuppressed {
            SecItemUpdate(exactQuery(identity) as CFDictionary,
                          [kSecValueData as String: data] as CFDictionary)
        }
        if status == errSecSuccess {
            pending = nil
            lastKnownGood = updated
            return
        }
        if Self.isACLBlockedStatus(status) {
            pending = (identity, updated)
            lastKnownGood = updated
            AppLog.keychain.error("Keychain persistence blocked; token retained in memory for the same item. Use Authorize in the Claude card.")
            return
        }
        // No SecItemAdd or service-only fallback: disappearing credentials are
        // owned by the CLI and must never be recreated/overwritten here.
        if status == errSecItemNotFound || status == errSecInvalidItemRef {
            target = nil
            pending = nil
            lastKnownGood = nil
        }
        throw Self.errorFor(status: status, op: "update selected credential")
    }

    public func invalidateCachedCredentials() {
        credentialMutationGate.lock()
        defer { credentialMutationGate.unlock() }
        lastKnownGood = nil
        pending = nil
    }

    internal func seedLastKnownGoodForTesting(_ credentials: AnthropicCredentials) {
        credentialMutationGate.lock()
        defer { credentialMutationGate.unlock() }
        lastKnownGood = credentials
    }

    internal var testingLastKnownGood: AnthropicCredentials? {
        credentialMutationGate.lock()
        defer { credentialMutationGate.unlock() }
        return lastKnownGood
    }

    internal func seedPendingUpdateForTesting(_ credentials: AnthropicCredentials) {
        credentialMutationGate.lock()
        defer { credentialMutationGate.unlock() }
        pending = (target, credentials)
    }

    internal var testingPendingUpdate: AnthropicCredentials? {
        credentialMutationGate.lock()
        defer { credentialMutationGate.unlock() }
        return pending?.credentials
    }

    internal static func isACLBlockedStatus(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    internal static func errorFor(status: OSStatus, op: String) -> AppError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed:
            let token = status == errSecAuthFailed ? "errSecAuthFailed" : "errSecInteractionNotAllowed"
            return .credentials("Keychain access denied (\(token)). Click Authorize in the Claude card. macOS handles permission; the app never receives your Keychain password.")
        default:
            return .credentials("Keychain \(op) failed (OSStatus \(status)). Run Claude Code if the credential is missing.")
        }
    }

    // Silent reads preserve freshest-wins, then bind the selected persistent ref.
    // Authorization and an unbound write remain strict about ambiguous accounts.
    internal struct KeychainItem {
        let account: String
        let data: Data
        var identity: KeychainAccessAuthorizer.TargetIdentity? = nil
    }

    internal func select(from items: [KeychainItem]) -> KeychainItem {
        if let preferred = preferredAccount,
           let match = items.first(where: { $0.account == preferred }) {
            return match
        }
        if items.count == 1 { return items[0] }
        // Freshest-wins: prefer the candidate whose decoded credentials expire
        // latest. Self-healing against stale, orphaned items an older Claude
        // Code version left behind (e.g. a legacy account-less blob shadowing
        // the account-bearing entry the current CLI keeps refreshed).
        // Undecodable items and exact ties break lexicographically so the
        // choice stays deterministic.
        let sorted = items.sorted { a, b in
            let ea = decodedExpiry(a) ?? Int64.min
            let eb = decodedExpiry(b) ?? Int64.min
            if ea != eb { return ea > eb }
            return a.account < b.account
        }
        // Service is a well-known identifier; account names can be
        // email-shaped — redact each one to <private> in sysdiagnose uploads
        // while remaining visible in the user's own Console.app.
        let count = sorted.count
        let svc = self.service
        let accounts = sorted.map(\.account).joined(separator: ", ")
        let chosen = sorted[0].account
        AppLog.keychain.info("Found \(count, privacy: .public) Keychain entries for service \(svc, privacy: .public) [\(accounts, privacy: .private)]. Using \(chosen, privacy: .private) (freshest token). Set `keychain_account` under [anthropic] in config.toml to pin.")
        return sorted[0]
    }

    /// Decodes an item's `expiresAt` (ms since epoch), or `nil` when the blob
    /// isn't valid Claude credentials JSON. Used by `select` to rank
    /// candidates by freshness.
    private func decodedExpiry(_ item: KeychainItem) -> Int64? {
        try? SharedCoders.decoder
            .decode(AnthropicCredentialsFile.self, from: item.data)
            .claudeAiOauth.expiresAtMs
    }

}

/// Pure reconciliation between the on-disk Keychain copy and the in-memory
/// `pendingUpdate` cache. Extracted so the freshness-wins / dropPending
/// invariant can be unit-tested without touching the real Keychain.
public enum CredentialReconciliation {
    public struct Verdict: Equatable {
        public let credentials: AnthropicCredentials
        /// True when disk won — caller should clear the in-memory pending copy
        /// because it's now stale relative to what the Keychain holds.
        public let dropPending: Bool
    }

    /// Picks the freshest available credential copy.
    /// Returns nil iff both `disk` and `pending` are nil — caller must throw.
    public static func pick(disk: AnthropicCredentials?,
                            pending: AnthropicCredentials?) -> Verdict? {
        switch (disk, pending) {
        case (.some(let d), .some(let p)):
            // Reconcile: the freshest `expiresAtMs` wins. If an external
            // refresher (e.g. Claude Code CLI re-auth) wrote a newer token
            // to disk while we held a stale in-memory copy, prefer disk
            // and drop the pending. If our pending is still ahead, keep
            // it — the next successful writeBack will clear it.
            if d.expiresAtMs >= p.expiresAtMs {
                return Verdict(credentials: d, dropPending: true)
            }
            return Verdict(credentials: p, dropPending: false)
        case (.some(let d), .none):
            return Verdict(credentials: d, dropPending: false)
        case (.none, .some(let p)):
            // Keychain unreadable (ACL block, schema error, …) but the
            // in-memory copy is still good. This is the very state the
            // `pendingUpdate` cache exists to cover.
            return Verdict(credentials: p, dropPending: false)
        case (.none, .none):
            return nil
        }
    }
}
