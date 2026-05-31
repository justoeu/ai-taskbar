import Foundation
import Security
import LocalAuthentication

/// Reads/writes the Claude Code OAuth credentials JSON blob from the macOS
/// login keychain. The Claude Code CLI stores it under
/// `kSecAttrService = "Claude Code-credentials"` as a generic password.
///
/// Multi-account support: a user may have multiple Claude entries
/// (work + personal). The reader resolves the match deterministically and
/// caches the chosen `kSecAttrAccount` so `writeBack` targets the same item.
/// Pass `preferredAccount` (from `[anthropic] keychain_account = "..."` in
/// config) to pin to a specific entry; otherwise the lexicographically
/// smallest account name wins and a warning is logged.
/// Conforms to `AnthropicCredentialReading` so tests can substitute an
/// in-memory mock without subclassing this concrete reader — the class
/// stays `final` and the production credential surface is interception-
/// proof for any external consumer.
public final class KeychainCredentialReader: AnthropicCredentialReading, @unchecked Sendable {
    public let service: String
    public let preferredAccount: String?

    private let lock = NSLock()
    private var _resolvedAccount: String?
    /// In-memory mirror of the most recent successful OAuth refresh whose
    /// `writeBack` was blocked by an ACL mismatch. Read paths return this in
    /// preference to the on-disk Keychain item so that **refresh_token
    /// rotation survives across refresh cycles** even when the Keychain ACL
    /// doesn't trust the current binary — without this, a successful
    /// rotation that can't persist would be re-attempted with the now-stale
    /// disk token on the next cycle and fail with `invalid_grant`.
    /// Cleared on any successful Keychain write.
    private var _pendingUpdate: AnthropicCredentials?

    /// Reused LAContext for no-UI Keychain queries. macOS 11 deprecated
    /// `kSecUseAuthenticationUIFail`; the modern replacement is to pass an
    /// `LAContext` with `interactionNotAllowed = true` via
    /// `kSecUseAuthenticationContext`. Shared across all 4 SecItem queries
    /// — LAContext is reusable in no-UI mode and avoids per-call allocation.
    private let laContext: LAContext = {
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        return ctx
    }()

    public init(service: String = "Claude Code-credentials",
                preferredAccount: String? = nil) {
        self.service = service
        self.preferredAccount = preferredAccount
    }

    public func read() throws -> AnthropicCredentials {
        // Prefer the in-memory copy if a prior writeBack was blocked. This
        // is what keeps OAuth refresh_token rotation safe across cycles when
        // the Keychain item's ACL no longer trusts our cdhash.
        if let pending = getPendingUpdate() {
            return pending
        }
        let items = try fetchAll()
        if items.isEmpty {
            throw AppError.credentials(
                "Keychain item '\(service)' not found. Run Claude Code at least once.")
        }
        let chosen = select(from: items)
        setResolvedAccount(chosen.account)
        do {
            return try SharedCoders.decoder
                .decode(AnthropicCredentialsFile.self, from: chosen.data)
                .claudeAiOauth
        } catch {
            throw AppError.schema("decoding Claude credentials JSON: \(error)")
        }
    }

    public func writeBack(_ updated: AnthropicCredentials) throws {
        let file = AnthropicCredentialsFile(claudeAiOauth: updated)
        let data = try SharedCoders.encoder.encode(file)
        var query: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            // Same rationale as the reads: we're LSUIElement (no Dock icon),
            // so a SecurityAgent password prompt would freeze the refresh
            // cycle behind an invisible window. Fast-fail with
            // errSecInteractionNotAllowed and let the caller-side branch
            // below treat persistence as best-effort.
            kSecUseAuthenticationContext as String: laContext,
        ]
        // Pin to the account we resolved on read so we never accidentally
        // overwrite an unrelated entry (work vs personal). Skip empty-string
        // accounts: a legacy Claude Code item has NO `kSecAttrAccount` at
        // all, so pinning `kSecAttrAccount = ""` would not match it and
        // `SecItemUpdate` would return `errSecItemNotFound`, sending us
        // through `SecItemAdd` and forking the credential into a duplicate
        // entry with an empty-string account.
        if let account = getResolvedAccount() ?? preferredAccount, !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            setPendingUpdate(nil)
            return
        }
        if status == errSecInteractionNotAllowed {
            // Disk persistence blocked; stash the renewed credentials in
            // memory so the next `read()` returns the rotated tokens
            // instead of the stale on-disk ones.
            setPendingUpdate(updated)
            logACLMismatch(op: "update")
            return
        }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecSuccess {
                setPendingUpdate(nil)
                return
            }
            if addStatus == errSecInteractionNotAllowed {
                setPendingUpdate(updated)
                logACLMismatch(op: "add")
                return
            }
            // Route through `errorFor` so locked-keychain / auth-failed
            // codes carry the curated user-facing hint instead of a raw
            // OSStatus number.
            throw Self.errorFor(status: addStatus, op: "writeBack add")
        }
        throw Self.errorFor(status: status, op: "writeBack update")
    }

    /// Logged (not thrown) only on `errSecInteractionNotAllowed` during a
    /// write. The OAuth refresh that produced `updated` already succeeded in
    /// memory, so the current fetch can proceed — only persistence to the
    /// Keychain item was blocked by an ACL the binary doesn't satisfy
    /// (typical for ad-hoc rebuilds whose cdhash changes). The next refresh
    /// cycle will try again. Surfacing this in Console.app rather than
    /// throwing prevents the menu-bar app from breaking on every OAuth
    /// rotation while still giving the user a discoverable hint.
    private func logACLMismatch(op: String) {
        NSLog(
            "ai-taskbar: Keychain %@ skipped (errSecInteractionNotAllowed). " +
            "Token kept in memory; persistence will retry next cycle. " +
            "Silence this by running: security set-generic-password-partition-list " +
            "-S apple-tool:,apple:,unsigned: -s \"%@\" -a \"$(whoami)\" -k login",
            op, service
        )
    }

    // MARK: - Internals

    /// Internal-visibility so test targets can drive `select(from:)` without
    /// touching the real Keychain.
    internal struct KeychainItem {
        let account: String
        let data: Data
    }

    /// Resolution strategy:
    ///
    /// 1. **Fast path (single-pass, 1 SecItem call):** when there's no
    ///    `preferredAccount` in config, use the legacy single-limit query
    ///    filtered by service only. This is one ACL operation, so a single
    ///    "Always Allow" click silences future prompts. Vast majority of
    ///    users have one Claude entry → this is the common case.
    ///
    /// 2. **Disambiguation path (two-pass, 2 SecItem calls):** only when
    ///    the user explicitly set `keychain_account = "…"` in config (or
    ///    the fast path returned nothing). We list accounts first, then
    ///    fetch each one's data. Each pass is a separate ACL operation, so
    ///    users see two prompts on first launch but never again.
    ///
    /// macOS rejects the combination
    /// `kSecMatchLimitAll + kSecReturnAttributes + kSecReturnData` in a single
    /// query with `errSecParam` (-50), so the two-pass is unavoidable for
    /// disambiguation.
    private func fetchAll() throws -> [KeychainItem] {
        if preferredAccount == nil {
            if let single = try fetchLegacySingle() {
                return [single]
            }
            // Single-pass returned nothing — fall through to enumeration in
            // case the keychain holds items only matchable by account.
        }
        let accounts = try listAccounts()
        if accounts.isEmpty {
            if let legacy = try fetchLegacySingle() {
                return [legacy]
            }
            return []
        }
        return accounts.compactMap { account in
            guard let data = try? fetchData(for: account) else { return nil }
            return KeychainItem(account: account, data: data)
        }
    }

    private func listAccounts() throws -> [String] {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            kSecMatchLimit as String:          kSecMatchLimitAll,
            kSecReturnAttributes as String:    true,
            // CRITICAL: skip UI prompt. For ad-hoc-signed apps whose cdhash
            // changes on every rebuild, the system would otherwise hang
            // waiting on a SecurityAgent prompt that's invisible because
            // we're an LSUIElement (no Dock icon) menu bar app. Fast-fail
            // with errSecInteractionNotAllowed is recoverable; an invisible
            // hang is not.
            kSecUseAuthenticationContext as String: laContext,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw Self.errorFor(status: status, op: "list")
        }
        guard let array = item as? [[String: Any]] else { return [] }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func fetchData(for account: String) throws -> Data {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            kSecAttrAccount as String:         account,
            kSecMatchLimit as String:          kSecMatchLimitOne,
            kSecReturnData as String:          true,
            kSecUseAuthenticationContext as String: laContext,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw Self.errorFor(status: status, op: "data for '\(account)'")
        }
        return data
    }

    /// Backward-compat path for keychain items that were created without an
    /// account attribute (older Claude Code versions). Single-limit query
    /// filtered only by service.
    private func fetchLegacySingle() throws -> KeychainItem? {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            kSecMatchLimit as String:          kSecMatchLimitOne,
            kSecReturnData as String:          true,
            kSecUseAuthenticationContext as String: laContext,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return KeychainItem(account: "", data: data)
    }

    /// Maps an OSStatus into a meaningful AppError. The common
    /// `errSecInteractionNotAllowed` (-25308) deserves a specific hint
    /// because it's what happens on every rebuild — we tell the user
    /// exactly how to re-authorize via `security set-generic-password-partition-list`.
    internal static func errorFor(status: OSStatus, op: String) -> AppError {
        switch status {
        case errSecInteractionNotAllowed:
            return .credentials("""
                Keychain access denied (errSecInteractionNotAllowed). \
                The Keychain ACL doesn't recognize this build. Fix: open Terminal and run:
                  security set-generic-password-partition-list -S apple-tool:,apple:,unsigned: -s "Claude Code-credentials" -a "$(whoami)" -k login
                (you'll be prompted for your login password). Then relaunch AI Taskbar.
                """)
        case errSecAuthFailed:
            return .credentials("Keychain auth failed (-25293). Try unlocking your Login Keychain in Keychain Access.")
        default:
            return .credentials("SecItemCopyMatching (\(op)) failed (OSStatus \(status))")
        }
    }

    internal func select(from items: [KeychainItem]) -> KeychainItem {
        if let preferred = preferredAccount,
           let match = items.first(where: { $0.account == preferred }) {
            return match
        }
        if items.count == 1 { return items[0] }
        let sorted = items.sorted { $0.account < $1.account }
        NSLog(
            "ai-taskbar: Found %d Keychain entries for service '%@' [%@]. " +
            "Using '%@'. Set `keychain_account` under [anthropic] in config.toml to pin.",
            sorted.count, service, sorted.map(\.account).joined(separator: ", "),
            sorted[0].account
        )
        return sorted[0]
    }

    private func setResolvedAccount(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        _resolvedAccount = s
    }
    private func getResolvedAccount() -> String? {
        lock.lock(); defer { lock.unlock() }
        return _resolvedAccount
    }
    private func setPendingUpdate(_ v: AnthropicCredentials?) {
        lock.lock(); defer { lock.unlock() }
        _pendingUpdate = v
    }
    private func getPendingUpdate() -> AnthropicCredentials? {
        lock.lock(); defer { lock.unlock() }
        return _pendingUpdate
    }
}
