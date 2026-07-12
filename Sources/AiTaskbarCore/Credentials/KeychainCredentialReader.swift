import Foundation
import Security
import os

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

    /// Both pieces of mutable state live behind a single
    /// `OSAllocatedUnfairLock` — replaces the previous `NSLock` + two `var`
    /// fields with a structured value-typed state guarded by one cheap
    /// kernel primitive. macOS 13+ only, which matches our deployment
    /// target.
    ///
    /// - `resolvedAccount` — the `kSecAttrAccount` chosen during the last
    ///   successful `read()`. Pinned so `writeBack` targets the same
    ///   entry. Empty strings are normalized to `nil` at the set site so
    ///   the `getResolvedAccount() ?? preferredAccount` fallback chain
    ///   works as intended.
    /// - `pendingUpdate` — in-memory mirror of the most recent successful
    ///   OAuth refresh whose `writeBack` was blocked by an ACL mismatch.
    ///   Consulted by `read()` and reconciled against the on-disk copy:
    ///   whichever has the later `expiresAtMs` wins. Cleared when the
    ///   disk copy catches up or surpasses it (e.g. Claude Code CLI
    ///   re-auth wrote a fresher token).
    /// - `lastKnownGood` — last credentials successfully obtained (disk or
    ///   pending). Used as a process-lifetime read cache so scheduled
    ///   refreshes do not hammer `SecItemCopyMatching` every cadence while
    ///   the access token is still valid. Also bridges ACL regressions:
    ///   if Keychain becomes unreadable mid-session, we keep serving the
    ///   cached token until it is near expiry.
    /// - `hadSuccessfulKeychainRead` — true after at least one disk read
    ///   succeeded this process. Lets us log + surface a clearer "ACL
    ///   regressed" message when a later read fails with InteractionNotAllowed.
    private struct LockedState {
        var resolvedAccount: String?
        var pendingUpdate: AnthropicCredentials?
        var lastKnownGood: AnthropicCredentials?
        var hadSuccessfulKeychainRead: Bool = false
    }
    private let state = OSAllocatedUnfairLock(initialState: LockedState())

    /// How long before `expiresAt` we still treat `lastKnownGood` as
    /// cacheable without re-hitting Keychain. Matches the OAuth refresh
    /// buffer so we re-read (and surface ACL issues) before the usage API
    /// would 401.
    public static let memoryCacheBuffer: TimeInterval = 300

    public init(service: String = "Claude Code-credentials",
                preferredAccount: String? = nil) {
        self.service = service
        self.preferredAccount = preferredAccount
    }

    public func read() throws -> AnthropicCredentials {
        // Fast path: process-lifetime memory cache. Avoids a SecItem call on
        // every scheduled Anthropic tick while the token is still valid.
        // Does not skip Keychain when the token is near expiry — we need a
        // fresh disk/pending copy (or a clear ACL error) before the usage
        // request would 401.
        if let cached = getLastKnownGood(),
           !cached.isExpired(buffer: Self.memoryCacheBuffer) {
            return cached
        }

        // Always attempt the Keychain read so its side effect — setting
        // `resolvedAccount` — runs regardless of which copy ends up winning.
        // Without that side effect a future `writeBack` would forget which
        // entry to update.
        let diskResult = readFromKeychain()
        let pending = getPendingUpdate()
        let diskCreds = try? diskResult.get()
        if diskCreds != nil {
            markSuccessfulKeychainRead()
        } else if case .failure(let err) = diskResult, err.isKeychainACLBlocked {
            logACLRegressionIfNeeded()
        }

        // Pure reconciliation over (disk, pending). Returns nil when neither
        // copy is available — caller throws the original Keychain error.
        guard let verdict = CredentialReconciliation.pick(disk: diskCreds,
                                                           pending: pending) else {
            // Last-chance: serve lastKnownGood even if near expiry when the
            // only failure is ACL (banner still surfaces if the fetch 401s).
            if case .failure(let err) = diskResult,
               err.isKeychainACLBlocked,
               let stale = getLastKnownGood() {
                AppLog.keychain.warning("Keychain ACL blocked; serving last-known-good token until expiry")
                return stale
            }
            // Re-throw the underlying Keychain error (preserves its
            // service/account context for the user-facing message).
            switch diskResult {
            case .failure(let err): throw err
            case .success:          throw AppError.credentials("no credentials available")
            }
        }
        if verdict.dropPending {
            setPendingUpdate(nil)
        }
        setLastKnownGood(verdict.credentials)
        return verdict.credentials
    }

    /// Explicit, user-initiated credential read. Unlike scheduled `read()`,
    /// this permits SecurityAgent UI and seeds `lastKnownGood` so subsequent
    /// automatic refreshes can reuse the credential in memory without
    /// prompting. It does not mutate another app's Keychain ACL.
    public func readInteractively() throws -> AnthropicCredentials {
        let interactionStatus = SecKeychainSetUserInteractionAllowed(true)
        guard interactionStatus == errSecSuccess else {
            throw Self.errorFor(status: interactionStatus,
                                op: "enable user-initiated interaction")
        }
        let items = try fetchAll(interactive: true)
        guard !items.isEmpty else {
            throw AppError.credentials(
                "Keychain item '\(service)' not found. Run Claude Code at least once.")
        }
        let chosen = select(from: items)
        let credentials: AnthropicCredentials
        do {
            credentials = try SharedCoders.decoder
                .decode(AnthropicCredentialsFile.self, from: chosen.data)
                .claudeAiOauth
        } catch {
            throw AppError.schema("decoding Claude credentials JSON: \(error)")
        }
        setResolvedAccount(chosen.account)
        setLastKnownGood(credentials)
        markSuccessfulKeychainRead()
        return credentials
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

extension KeychainCredentialReader {
    // MARK: - Internals (continued below)

    /// Captures the Keychain side of `read()` so the reconciliation in
    /// `read()` itself stays a pure `(Result, pending?) → outcome` switch.
    private func readFromKeychain() -> Result<AnthropicCredentials, AppError> {
        do {
            let items = try fetchAll()
            if items.isEmpty {
                return .failure(.credentials(
                    "Keychain item '\(service)' not found. Run Claude Code at least once."))
            }
            let chosen = select(from: items)
            setResolvedAccount(chosen.account)
            do {
                let creds = try SharedCoders.decoder
                    .decode(AnthropicCredentialsFile.self, from: chosen.data)
                    .claudeAiOauth
                return .success(creds)
            } catch {
                return .failure(.schema("decoding Claude credentials JSON: \(error)"))
            }
        } catch let appErr as AppError {
            return .failure(appErr)
        } catch {
            return .failure(.other(String(describing: error)))
        }
    }

    public func writeBack(_ updated: AnthropicCredentials) throws {
        let file = AnthropicCredentialsFile(claudeAiOauth: updated)
        let data = try SharedCoders.encoder.encode(file)
        var query: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            // Deliberate use of the deprecated `kSecUseAuthenticationUIFail`.
            //
            // The modern replacement (`kSecUseAuthenticationContext` carrying
            // an `LAContext` with `interactionNotAllowed = true`) only
            // suppresses the SecurityAgent prompt for Keychain items stored
            // with a `SecAccessControl` carrying a LocalAuthentication
            // policy. The `Claude Code-credentials` item is a plain generic
            // password with no LA policy, so the LAContext route is silently
            // ignored and the prompt fires anyway — exactly what we saw in
            // the field after migrating away from this key. The deprecated
            // switch is the ONLY documented way to fast-fail with
            // `errSecInteractionNotAllowed` for plain-generic-password items.
            // Apple has been promising to remove it for years; do not migrate
            // until they ship a working replacement.
            //
            // UIFail is NOT sufficient on its own: it silences only the
            // trusted-app Allow/Deny confirmation. The partition-list
            // PASSWORD dialog ignores it, and only
            // `SecKeychainSetUserInteractionAllowed(false)` blocks it —
            // hence every SecItem call here also runs inside
            // `KeychainPromptSuppressor.withPromptsSuppressed`, under which
            // that dialog degrades to `errSecAuthFailed` (-25293).
            //
            // Same rationale applies to the read paths below — they share
            // the brief pointer comment back to here.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
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
        let status = KeychainPromptSuppressor.withPromptsSuppressed {
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        if status == errSecSuccess {
            setPendingUpdate(nil)
            setLastKnownGood(updated)
            return
        }
        if Self.isACLBlockedStatus(status) {
            // Disk persistence blocked; stash the renewed credentials in
            // memory so the next `read()` returns the rotated tokens
            // instead of the stale on-disk ones.
            setPendingUpdate(updated)
            setLastKnownGood(updated)
            logACLMismatch(op: "update")
            return
        }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = KeychainPromptSuppressor.withPromptsSuppressed {
                SecItemAdd(add as CFDictionary, nil)
            }
            if addStatus == errSecSuccess {
                setPendingUpdate(nil)
                setLastKnownGood(updated)
                return
            }
            if Self.isACLBlockedStatus(addStatus) {
                setPendingUpdate(updated)
                setLastKnownGood(updated)
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
        // op and service are operational identifiers (not secrets).
        // The full remediation command is part of the message — keep it
        // public so users copy-pasting from Console.app get the fix.
        let cmd = Self.remediationCommand(service: service)
        AppLog.keychain.error("Keychain \(op, privacy: .public) skipped (errSecInteractionNotAllowed). Token kept in memory; persistence will retry next cycle. Silence via: \(cmd, privacy: .public)")
    }

    /// The exact `security set-generic-password-partition-list` invocation
    /// that authorizes THIS build to read `service` without a SecurityAgent
    /// prompt. Two easy-to-get-wrong details, learned the hard way:
    /// - No `-a` filter: Claude Code's legacy item has a NULL account
    ///   attribute, so any `-a` value (even "") fails with "item not found".
    /// - No `-k`: it is the login-keychain PASSWORD (deprecated flag), not
    ///   the keychain name. Omitting it makes `security` prompt securely.
    /// The partition list keeps `apple:`/`apple-tool:`/`unsigned:` so the
    /// CLI and ad-hoc dev builds retain access, and appends this binary's
    /// `teamid:` when it's signed with a real identity.
    internal static func remediationCommand(service: String,
                                            teamID: String? = CodeSignatureInfo.currentTeamID()) -> String {
        var partitions = "apple-tool:,apple:,unsigned:"
        if let teamID {
            partitions += ",teamid:\(teamID)"
        }
        return "security set-generic-password-partition-list -S \"\(partitions)\" -s \"\(service)\" login.keychain-db"
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
    ///    users have one Claude entry → this is the common case. We trust
    ///    this result ONLY while its token is unexpired: the query can return
    ///    a stale orphan that shadows the live entry, so an expired hit
    ///    triggers the disambiguation path instead.
    ///
    /// 2. **Disambiguation path (two-pass, 2 SecItem calls):** when the user
    ///    set `keychain_account = "…"` in config, OR the fast path returned
    ///    nothing / an expired token. We list accounts first, then fetch each
    ///    one's data. Each pass is a separate ACL operation, so users see two
    ///    prompts on first launch but never again. Among the results,
    ///    `select` applies freshest-wins so a stale orphan never beats the
    ///    entry the current CLI keeps refreshed.
    ///
    /// macOS rejects the combination
    /// `kSecMatchLimitAll + kSecReturnAttributes + kSecReturnData` in a single
    /// query with `errSecParam` (-50), so the two-pass is unavoidable for
    /// disambiguation.
    private func fetchAll(interactive: Bool = false) throws -> [KeychainItem] {
        if !interactive, preferredAccount == nil {
            // Fast path: a single ACL operation, so one "Always Allow" click
            // silences future prompts for the overwhelmingly common
            // single-item case. BUT trust it only while the token it returns
            // is still valid. This service-only `kSecMatchLimitOne` query can
            // non-deterministically return a STALE, account-less blob left by
            // an older Claude Code version, which would shadow the fresh
            // account-bearing entry the current CLI keeps refreshed (observed
            // in the field: a 13-day-expired legacy item served instead of the
            // live one → persistent HTTP 401). On an expired hit, fall through
            // to full enumeration + freshest-wins in `select`.
            // `try?` (not `try`): an ACL-blocked data read here must NOT
            // abort the whole resolution — fall through to enumeration, which
            // reads attributes (never ACL-blocked) and may surface a readable
            // account-bearing entry the legacy single-query missed.
            if let single = try? fetchLegacySingle(interactive: false),
               let creds = try? SharedCoders.decoder
                   .decode(AnthropicCredentialsFile.self, from: single.data)
                   .claudeAiOauth,
               !creds.isExpired(buffer: 0) {
                return [single]
            }
            // Fast path returned nothing usable — fall through to enumeration.
        }
        let accounts = try listAccounts()
        if accounts.isEmpty {
            // `try` (not `try?`): with no account-bearing entries the legacy
            // item is our only shot, so an ACL block on it must propagate as
            // the ACL error (→ Authorize banner), not collapse to "not found".
            if let legacy = try fetchLegacySingle(interactive: interactive) {
                return [legacy]
            }
            return []
        }
        // Read each enumerated account's DATA. `listAccounts` (attributes) is
        // never ACL-gated, but the per-account data read IS: when the running
        // build isn't in the item's partition list, every read fast-fails with
        // errSecAuthFailed under `KeychainPromptSuppressor`. Do NOT silently
        // drop those — if EVERY entry is ACL-blocked, re-throw the ACL error so
        // the Anthropic card shows the Authorize banner instead of a misleading
        // "Keychain item not found. Run Claude Code" (the wrong remediation).
        // Non-ACL failures for a single account (e.g. a transient not-found)
        // are still dropped so a sibling readable entry can win.
        var items: [KeychainItem] = []
        var aclError: AppError?
        for account in accounts {
            do {
                let data = try fetchData(for: account, interactive: interactive)
                items.append(KeychainItem(account: account, data: data))
            } catch let err as AppError where err.isKeychainACLBlocked {
                aclError = err
            } catch {
                if interactive { throw error }
                // Drop non-ACL, per-account failures and keep trying siblings.
            }
        }
        if items.isEmpty, let aclError { throw aclError }
        return items
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
            // See `writeBack` for why we deliberately stick with the
            // deprecated `kSecUseAuthenticationUIFail` here. tl;dr: the
            // LAContext path only works for items stored with an LA-aware
            // `SecAccessControl`, which the `Claude Code-credentials`
            // generic password is not.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        let status = KeychainPromptSuppressor.withPromptsSuppressed {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw Self.errorFor(status: status, op: "list")
        }
        guard let array = item as? [[String: Any]] else { return [] }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func fetchData(for account: String, interactive: Bool = false) throws -> Data {
        var item: CFTypeRef?
        var query: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            kSecAttrAccount as String:         account,
            kSecMatchLimit as String:          kSecMatchLimitOne,
            kSecReturnData as String:          true,
        ]
        if !interactive {
            // See `writeBack` for why we deliberately stick with the
            // deprecated UIFail key for scheduled reads.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        let operation = { SecItemCopyMatching(query as CFDictionary, &item) }
        let status = interactive
            ? operation()
            : KeychainPromptSuppressor.withPromptsSuppressed(operation)
        guard status == errSecSuccess, let data = item as? Data else {
            throw Self.errorFor(status: status, op: "data for '\(account)'")
        }
        return data
    }

    /// Backward-compat path for keychain items that were created without an
    /// account attribute (older Claude Code versions). Single-limit query
    /// filtered only by service.
    private func fetchLegacySingle(interactive: Bool = false) throws -> KeychainItem? {
        var item: CFTypeRef?
        var query: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            kSecMatchLimit as String:          kSecMatchLimitOne,
            kSecReturnData as String:          true,
        ]
        if !interactive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        let operation = { SecItemCopyMatching(query as CFDictionary, &item) }
        let status = interactive
            ? operation()
            : KeychainPromptSuppressor.withPromptsSuppressed(operation)
        if status == errSecItemNotFound { return nil }
        // An ACL/partition-list block must be distinguishable from "no item":
        // the fast-path caller swallows it (`try?`) to fall through to
        // enumeration, but the `accounts.isEmpty` fallback lets it propagate so
        // a legacy-only, ACL-blocked item still lights up the Authorize banner
        // instead of reporting a bogus "not found".
        if Self.isACLBlockedStatus(status) {
            throw Self.errorFor(status: status, op: "legacy single")
        }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return KeychainItem(account: "", data: data)
    }

    /// The two OSStatus codes an ACL-blocked operation surfaces as while
    /// prompts are suppressed. `errSecInteractionNotAllowed` (-25308) is the
    /// UIFail fast-fail on the trusted-app confirmation; `errSecAuthFailed`
    /// (-25293) is what the partition-list check degrades to when
    /// `KeychainPromptSuppressor` blocks its password dialog (it also covers
    /// a locked login keychain — same remediation: the Authorize flow's
    /// interactive commit unlocks and fixes both).
    internal static func isACLBlockedStatus(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    /// Maps an OSStatus into a meaningful AppError. The two ACL-blocked
    /// codes (see `isACLBlockedStatus`) deserve a specific hint because
    /// they're what happens on every rebuild — we tell the user exactly how
    /// to re-authorize via `security set-generic-password-partition-list`.
    internal static func errorFor(status: OSStatus, op: String) -> AppError {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed:
            // Message must keep the OSStatus token so
            // `AppError.isKeychainACLBlocked` can match it.
            let token = status == errSecAuthFailed
                ? "errSecAuthFailed" : "errSecInteractionNotAllowed"
            return .credentials("""
                Keychain access denied (\(token)). \
                macOS is blocking this build from reading Claude Code-credentials \
                (partition list / trusted-app ACL), or the login keychain is locked. \
                Common after ad-hoc rebuilds or when the Claude Code CLI rewrites \
                the item. Tap Authorize in the Anthropic card (one system password \
                dialog), or run:
                  \(remediationCommand(service: "Claude Code-credentials"))
                Prefer the notarized app in /Applications so the signing identity stays stable.
                """)
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

    /// Stores the resolved account, normalizing empty strings to `nil` so
    /// `getResolvedAccount() ?? preferredAccount` falls back as intended.
    /// Legacy `fetchLegacySingle` items report `account = ""`, which would
    /// otherwise short-circuit the fallback and silently shadow the
    /// configured `keychain_account`.
    private func setResolvedAccount(_ s: String) {
        let normalized = s.isEmpty ? nil : s
        state.withLock { $0.resolvedAccount = normalized }
    }
    private func getResolvedAccount() -> String? {
        state.withLock { $0.resolvedAccount }
    }
    private func setPendingUpdate(_ v: AnthropicCredentials?) {
        state.withLock { $0.pendingUpdate = v }
    }
    private func getPendingUpdate() -> AnthropicCredentials? {
        state.withLock { $0.pendingUpdate }
    }
    private func setLastKnownGood(_ v: AnthropicCredentials?) {
        state.withLock { $0.lastKnownGood = v }
    }
    private func getLastKnownGood() -> AnthropicCredentials? {
        state.withLock { $0.lastKnownGood }
    }
    private func markSuccessfulKeychainRead() {
        state.withLock { $0.hadSuccessfulKeychainRead = true }
    }
    private func hadSuccessfulKeychainRead() -> Bool {
        state.withLock { $0.hadSuccessfulKeychainRead }
    }

    /// Logs once-ish when Keychain worked earlier this process but now
    /// returns InteractionNotAllowed — typically CLI rewrote ACL or the
    /// user switched from a Developer ID build to ad-hoc.
    private func logACLRegressionIfNeeded() {
        guard hadSuccessfulKeychainRead() else { return }
        let cmd = Self.remediationCommand(service: service)
        AppLog.keychain.error("Keychain ACL regressed after a successful read this session (errSecInteractionNotAllowed). Claude Code may have rewritten Claude Code-credentials, or this binary's signing identity no longer matches the trusted-app ACL. Tap Authorize on the Anthropic card, or: \(cmd, privacy: .public)")
    }
}
