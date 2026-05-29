import Foundation
import Security

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
/// Open for subclassing (drop the `final` modifier) specifically so test
/// targets can inject a mock that overrides `read()` / `writeBack()` without
/// touching the real Keychain. There's no production motivation to subclass
/// this elsewhere.
public class KeychainCredentialReader: @unchecked Sendable {
    public let service: String
    public let preferredAccount: String?

    private let lock = NSLock()
    private var _resolvedAccount: String?

    public init(service: String = "Claude Code-credentials",
                preferredAccount: String? = nil) {
        self.service = service
        self.preferredAccount = preferredAccount
    }

    open func read() throws -> AnthropicCredentials {
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

    open func writeBack(_ updated: AnthropicCredentials) throws {
        let file = AnthropicCredentialsFile(claudeAiOauth: updated)
        let data = try SharedCoders.encoder.encode(file)
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        // Pin to the account we resolved on read so we never accidentally
        // overwrite an unrelated entry (work vs personal).
        if let account = getResolvedAccount() ?? preferredAccount {
            query[kSecAttrAccount as String] = account
        }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AppError.credentials("SecItemAdd failed (OSStatus \(addStatus))")
            }
            return
        }
        throw AppError.credentials("SecItemUpdate failed (OSStatus \(status))")
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
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
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
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
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
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
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
}
