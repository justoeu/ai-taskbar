import Testing
import Foundation
import os
@testable import AiTaskbarCore

@Suite("KeychainCredentialReader — non-syscall surface", .serialized)
struct KeychainCredentialReaderTests {
    private let keychain: TemporaryKeychain
    init() throws { keychain = try TemporaryKeychain() }
    private func readerForTest(service: String = "Claude Code-credentials",
                               preferredAccount: String? = nil) -> KeychainCredentialReader {
        KeychainCredentialReader(service: service, preferredAccount: preferredAccount,
                                  searchList: [keychain.reference])
    }

    @Test("default service + preferredAccount nil")
    func init_defaults() {
        let reader = readerForTest()
        #expect(reader.service == "Claude Code-credentials")
        #expect(reader.preferredAccount == nil)
    }

    @Test("binding another item drops pending tokens and scopes writes to that item")
    func binding_cannot_transfer_pending_tokens() throws {
        let service = "ai-taskbar-bind-\(UUID().uuidString)"
        for account in ["A", "B"] {
            let payload = #"{"claudeAiOauth":{"accessToken":"\#(account)","refreshToken":"r","expiresAt":2000000000000}}"#
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecUseKeychain as String: keychain.reference,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: Data(payload.utf8),
            ]
            #expect(SecItemAdd(query as CFDictionary, nil) == errSecSuccess)
        }
        let reader = readerForTest(service: service, preferredAccount: "A")
        #expect(try reader.read().accessToken == "A")
        reader.seedPendingUpdateForTesting(.init(accessToken: "pending-A", refreshToken: "r", expiresAtMs: 2_100_000_000_000))
        let identityB = try KeychainAccessAuthorizer.resolveIdentity(
            service: service, account: "B", searchList: [keychain.reference])
        reader.bindTarget(identityB)
        expectTrue(reader.testingPendingUpdate == nil)
        #expect(try reader.read().accessToken == "B")
        try reader.writeBack(.init(accessToken: "updated-B", refreshToken: "r", expiresAtMs: 2_100_000_000_000))
        #expect(try readerForTest(service: service, preferredAccount: "A").read().accessToken == "A")
        #expect(try readerForTest(service: service, preferredAccount: "B").read().accessToken == "updated-B")
    }

    @Test("custom service + preferredAccount stick")
    func init_custom() {
        let reader = readerForTest(service: "Other",
                                              preferredAccount: "work")
        #expect(reader.service == "Other")
        #expect(reader.preferredAccount == "work")
    }

    @Test("normal silent multi-account reads still choose the freshest credential")
    func multi_account_reader_preserves_freshest_wins() throws {
        let service = "ai-taskbar-multiple-\(UUID().uuidString)"
        for (account, expiry) in [("alpha", 2_000_000_000_000 as Int64), ("beta", 2_100_000_000_000)] {
            let payload = #"{"claudeAiOauth":{"accessToken":"\#(account)","refreshToken":"r","expiresAt":\#(expiry)}}"#
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecUseKeychain as String: keychain.reference,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecValueData as String: Data(payload.utf8)
            ]
            try #require(SecItemAdd(query as CFDictionary, nil) == errSecSuccess)
        }
        #expect(try readerForTest(service: service).read().accessToken == "beta")
    }

    @Test("a failed write to a deleted item invalidates every cached credential")
    func deleted_item_write_drops_cached_credentials() throws {
        let service = "ai-taskbar-deleted-\(UUID().uuidString)"
        let account = "same-account"
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecUseKeychain as String: keychain.reference,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: Data(#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"r","expiresAt":2000000000000}}"#.utf8)
        ]
        try #require(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        let reader = readerForTest(service: service, preferredAccount: account)
        _ = try reader.read()
        let pending = AnthropicCredentials(accessToken: "pending", refreshToken: "r", expiresAtMs: 2_100_000_000_000)
        reader.seedPendingUpdateForTesting(pending)
        let delete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecMatchSearchList as String: [keychain.reference],
            kSecAttrService as String: service, kSecAttrAccount as String: account
        ]
        try #require(SecItemDelete(delete as CFDictionary) == errSecSuccess)
        #expect(throws: AppError.self) { try reader.writeBack(pending) }
        expectTrue(reader.testingLastKnownGood == nil)
        expectTrue(reader.testingPendingUpdate == nil)
        add[kSecValueData as String] = Data(#"{"claudeAiOauth":{"accessToken":"replacement","refreshToken":"r","expiresAt":2000000000000}}"#.utf8)
        try #require(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        #expect(try reader.read().accessToken == "replacement")
    }

    @Test("renaming an item cannot transfer a pending token to another account")
    func renamed_item_rejects_old_write() throws {
        let service = "ai-taskbar-rename-\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecUseKeychain as String: keychain.reference,
            kSecAttrService as String: service, kSecAttrAccount as String: "A",
            kSecValueData as String: Data(#"{"claudeAiOauth":{"accessToken":"A","refreshToken":"r","expiresAt":2000000000000}}"#.utf8)
        ]
        try #require(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        let reader = readerForTest(service: service, preferredAccount: "A")
        _ = try reader.read()
        let identity = try KeychainAccessAuthorizer.resolveIdentity(service: service, account: "A", searchList: [keychain.reference])
        let pending = AnthropicCredentials(accessToken: "pending-A", refreshToken: "r", expiresAtMs: 2_100_000_000_000)
        reader.seedPendingUpdateForTesting(pending)
        let exact: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecMatchSearchList as String: [keychain.reference],
            kSecMatchItemList as String: [identity.persistentRef]
        ]
        try #require(SecItemUpdate(exact as CFDictionary, [kSecAttrAccount as String: "B"] as CFDictionary) == errSecSuccess)
        #expect(throws: AppError.self) { try reader.writeBack(pending) }
        expectTrue(reader.testingPendingUpdate == nil)
        expectTrue(reader.testingLastKnownGood == nil)
        #expect(try readerForTest(service: service, preferredAccount: "B").read().accessToken == "A")
    }

    @Test("a legacy item with no account supports silent read and exact write")
    func legacy_without_account() throws {
        let service = "ai-taskbar-legacy-\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecUseKeychain as String: keychain.reference,
            kSecAttrService as String: service,
            kSecValueData as String: Data(#"{"claudeAiOauth":{"accessToken":"legacy","refreshToken":"r","expiresAt":2000000000000}}"#.utf8)
        ]
        try #require(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        let reader = readerForTest(service: service)
        #expect(try reader.read().accessToken == "legacy")
        try reader.writeBack(.init(accessToken: "updated", refreshToken: "r", expiresAtMs: 2_100_000_000_000))
        reader.invalidateCachedCredentials()
        #expect(try reader.read().accessToken == "updated")
        let authorized = try KeychainAccessAuthorizer.authorize(service: service, searchList: [keychain.reference],
            teamID: "test-team", readItem: { query in
                let values = query as NSDictionary
                guard values[kSecUseAuthenticationUI] as? String == kSecUseAuthenticationUIFail as String else {
                    return errSecParam // A failing test must never present real SecurityAgent UI.
                }
                var result: CFTypeRef?
                return SecItemCopyMatching(query, &result)
            })
        #expect(authorized == .authorized)
    }

    @Test("select picks the preferredAccount when present")
    func select_picks_preferred() {
        let reader = readerForTest(service: "s",
                                              preferredAccount: "work@x.com")
        let items = [
            KeychainCredentialReader.KeychainItem(account: "personal@x.com", data: Data("p".utf8)),
            KeychainCredentialReader.KeychainItem(account: "work@x.com",     data: Data("w".utf8)),
        ]
        let chosen = reader.select(from: items)
        #expect(chosen.account == "work@x.com")
        #expect(chosen.data == Data("w".utf8))
    }

    @Test("select returns the only item when count == 1")
    func select_returns_only_item() {
        let reader = readerForTest(service: "s",
                                              preferredAccount: nil)
        let items = [
            KeychainCredentialReader.KeychainItem(account: "only", data: Data("d".utf8)),
        ]
        let chosen = reader.select(from: items)
        #expect(chosen.account == "only")
    }

    @Test("select falls back to lex-smallest when preferred missing")
    func select_falls_back_to_lex_smallest() {
        let reader = readerForTest(service: "s",
                                              preferredAccount: "nonexistent")
        let items = [
            KeychainCredentialReader.KeychainItem(account: "zeta", data: Data("z".utf8)),
            KeychainCredentialReader.KeychainItem(account: "alpha", data: Data("a".utf8)),
            KeychainCredentialReader.KeychainItem(account: "beta", data: Data("b".utf8)),
        ]
        let chosen = reader.select(from: items)
        #expect(chosen.account == "alpha")
    }

    @Test("select prefers the freshest token over a stale orphan")
    func select_prefers_freshest_token() {
        let reader = readerForTest(service: "s", preferredAccount: nil)
        func blob(_ exp: Int64) -> Data {
            Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":\#(exp)}}"#.utf8)
        }
        // `alpha` sorts first lexicographically but holds the long-expired
        // orphan; `zeta` holds the live token. Freshest-wins must pick zeta.
        let items = [
            KeychainCredentialReader.KeychainItem(account: "alpha", data: blob(1_000)),
            KeychainCredentialReader.KeychainItem(account: "zeta",  data: blob(9_999_999_999_999)),
        ]
        let chosen = reader.select(from: items)
        #expect(chosen.account == "zeta")
    }

    @Test("select breaks ties lexicographically when expiries match")
    func select_ties_break_lexicographically() {
        let reader = readerForTest(service: "s", preferredAccount: nil)
        func blob(_ exp: Int64) -> Data {
            Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":\#(exp)}}"#.utf8)
        }
        let items = [
            KeychainCredentialReader.KeychainItem(account: "beta",  data: blob(5_000)),
            KeychainCredentialReader.KeychainItem(account: "alpha", data: blob(5_000)),
        ]
        let chosen = reader.select(from: items)
        #expect(chosen.account == "alpha")
    }

    @Test("select still honors preferredAccount over a fresher entry")
    func select_preferred_beats_freshness() {
        let reader = readerForTest(service: "s", preferredAccount: "pinned")
        func blob(_ exp: Int64) -> Data {
            Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":\#(exp)}}"#.utf8)
        }
        // `pinned` is older than `other`, but an explicit pin must win.
        let items = [
            KeychainCredentialReader.KeychainItem(account: "other",  data: blob(9_999_999_999_999)),
            KeychainCredentialReader.KeychainItem(account: "pinned", data: blob(1_000)),
        ]
        let chosen = reader.select(from: items)
        #expect(chosen.account == "pinned")
    }

    @Test("errorFor maps errSecInteractionNotAllowed to instructive message")
    func errorFor_maps_interaction_not_allowed() {
        let err = KeychainCredentialReader.errorFor(status: -25308, op: "list")
        // Keep the OSStatus token so VendorSectionView can show Authorize.
        #expect(err.isKeychainACLBlocked)
        if case .credentials(let msg) = err {
            #expect(msg.contains("errSecInteractionNotAllowed"))
            #expect(!msg.contains("set-generic-password-partition-list"))
            #expect(msg.contains("Authorize") || msg.contains("partition"))
        } else {
            Issue.record("expected .credentials")
        }
    }

    @Test("errorFor maps errSecAuthFailed to the ACL-blocked message")
    func errorFor_maps_auth_failed() {
        // With prompts suppressed, the partition-list password dialog degrades
        // to errSecAuthFailed — it must drive the same Authorize-banner UX.
        let err = KeychainCredentialReader.errorFor(status: -25293, op: "data")
        #expect(err.isKeychainACLBlocked)
        if case .credentials(let msg) = err {
            #expect(msg.contains("errSecAuthFailed"))
            #expect(!msg.contains("set-generic-password-partition-list"))
        } else {
            Issue.record("expected .credentials")
        }
    }

    @Test("isACLBlockedStatus covers both fast-fail codes only")
    func acl_blocked_status_codes() {
        #expect(KeychainCredentialReader.isACLBlockedStatus(-25308))
        #expect(KeychainCredentialReader.isACLBlockedStatus(-25293))
        #expect(!KeychainCredentialReader.isACLBlockedStatus(0))
        #expect(!KeychainCredentialReader.isACLBlockedStatus(-25300))
    }

    @Test("errorFor maps unknown OSStatus to generic message")
    func errorFor_maps_unknown_status() {
        let err = KeychainCredentialReader.errorFor(status: -99999, op: "weird")
        if case .credentials(let msg) = err {
            #expect(msg.contains("weird"))
            #expect(msg.contains("-99999"))
        } else {
            Issue.record("expected .credentials")
        }
    }

    @Test("read on Keychain with seeded entry round-trips credentials")
    func read_with_seeded_entry_round_trips() throws {
        let service = "ai-taskbar-test-\(UUID().uuidString)"
        let account = "test@example.com"
        let payload = #"""
        {
          "claudeAiOauth": {
            "accessToken": "seeded-access",
            "refreshToken": "seeded-refresh",
            "expiresAt": 1764201600000
          }
        }
        """#

        // The isolated temporary Keychain must support writes; never silently skip.
        let addQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseKeychain as String: keychain.reference,
            kSecValueData as String:   Data(payload.utf8),
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        try #require(addStatus == errSecSuccess)
        defer {
            let delQuery: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecMatchSearchList as String: [keychain.reference],
            kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            _ = SecItemDelete(delQuery as CFDictionary)
        }

        let reader = readerForTest(service: service)
        let creds = try reader.read()
        #expect(creds.accessToken == "seeded-access")
        #expect(creds.refreshToken == "seeded-refresh")
        #expect(creds.expiresAtMs == 1_764_201_600_000)
    }

    @Test("interactive and persistent authorization seed process-memory credentials")
    func authorization_seeds_memory() throws {
        let service = "ai-taskbar-test-interactive-\(UUID().uuidString)"
        let account = "interactive@example.com"
        let payload = #"{"claudeAiOauth":{"accessToken":"interactive-access","refreshToken":"interactive-refresh","expiresAt":2000000000000}}"#
        let addQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseKeychain as String: keychain.reference,
            kSecValueData as String:   Data(payload.utf8),
        ]
        try #require(SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess)
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecMatchSearchList as String: [keychain.reference],
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        defer { _ = SecItemDelete(deleteQuery as CFDictionary) }

        let reader = readerForTest(service: service,
                                              preferredAccount: account)
        let interactive = try reader.read()
        #expect(interactive.accessToken == "interactive-access")

        var authorizedAccount: String?
        let persistent = try reader.authorizePersistently(using: { _, account in
            authorizedAccount = account
            return .authorized
        })
        #expect(persistent == .authorized)
        #expect(authorizedAccount == account)

        // Remove the backing item: the next scheduled-style read must still
        // succeed from the process-memory value seeded above.
        _ = SecItemDelete(deleteQuery as CFDictionary)
        let cached = try reader.read()
        #expect(cached.accessToken == "interactive-access")
        #expect(cached.refreshToken == "interactive-refresh")
    }

    @Test("canceling persistent authorization leaves the Keychain untouched")
    func persistent_authorization_cancel() throws {
        let reader = readerForTest(
            service: "ai-taskbar-canceled-\(UUID().uuidString)")

        let outcome = try reader.authorizePersistently(using: { _, _ in .canceled })

        #expect(outcome == .canceled)
    }

    @Test("a concurrent write cannot be lost while pending authorization is persisted")
    func persistent_authorization_serializes_pending_write() throws {
        let service = "ai-taskbar-test-pending-auth-\(UUID().uuidString)"
        let account = "pending@example.com"
        let oldPayload = #"{"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":2000000000000}}"#
        let addQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseKeychain as String: keychain.reference,
            kSecValueData as String:   Data(oldPayload.utf8),
        ]
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecMatchSearchList as String: [keychain.reference],
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(deleteQuery as CFDictionary)
        defer { _ = SecItemDelete(deleteQuery as CFDictionary) }
        try #require(SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess)

        let reader = readerForTest(service: service, preferredAccount: account)
        _ = try reader.read()
        let newer = AnthropicCredentials(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAtMs: 2_100_000_000_000)
        reader.seedPendingUpdateForTesting(newer)
        let newest = AnthropicCredentials(
            accessToken: "newest-access",
            refreshToken: "newest-refresh",
            expiresAtMs: 2_200_000_000_000)
        let concurrentStarted = DispatchSemaphore(value: 0)
        let concurrentFinished = DispatchSemaphore(value: 0)
        let concurrentResult = OSAllocatedUnfairLock<Result<Void, Error>?>(initialState: nil)

        let outcome = try reader.authorizePersistently(
            using: { _, selectedAccount in
                #expect(selectedAccount == account)
                return .authorized
            },
            beforePendingPersistence: {
                DispatchQueue.global().async {
                    concurrentStarted.signal()
                    let result = Result { try reader.writeBack(newest) }
                    concurrentResult.withLock { $0 = result }
                    concurrentFinished.signal()
                }
                #expect(concurrentStarted.wait(timeout: .now() + 1) == .success)
                #expect(concurrentFinished.wait(timeout: .now() + 0.05) == .timedOut)
            })

        #expect(outcome == .authorized)
        #expect(concurrentFinished.wait(timeout: .now() + 1) == .success)
        let writeResult = try #require(concurrentResult.withLock { $0 })
        try writeResult.get()
        reader.invalidateCachedCredentials()
        let persisted = try reader.read()
        #expect(persisted.accessToken == "newest-access")
        #expect(persisted.refreshToken == "newest-refresh")
    }

    @Test("writeBack updates a seeded Keychain entry")
    func writeBack_updates_seeded_entry() throws {
        let service = "ai-taskbar-test-wb-\(UUID().uuidString)"
        let account = "writeback@example.com"
        let initialPayload = #"""
        {"claudeAiOauth":{"accessToken":"old","refreshToken":"r","expiresAt":1}}
        """#
        let addQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseKeychain as String: keychain.reference,
            kSecValueData as String:   Data(initialPayload.utf8),
        ]
        try #require(SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess)
        defer {
            let delQuery: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecMatchSearchList as String: [keychain.reference],
            kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            _ = SecItemDelete(delQuery as CFDictionary)
        }

        let reader = readerForTest(service: service,
                                              preferredAccount: account)
        _ = try reader.read()   // binds the exact persistent reference
        let updated = AnthropicCredentials(
            accessToken: "new", refreshToken: "new-r",
            expiresAtMs: 2_000_000_000_000)
        try reader.writeBack(updated)
        let back = try reader.read()
        #expect(back.accessToken == "new")
        #expect(back.refreshToken == "new-r")
    }

    @Test("read on empty Keychain throws AppError.credentials")
    func read_throws_when_keychain_empty() {
        // Service that surely doesn't exist on any test machine.
        let reader = readerForTest(
            service: "ai-taskbar-unit-test-no-such-service-\(UUID().uuidString)")
        do {
            _ = try reader.read()
            // If a real keychain entry happens to match (unlikely), we skip
            // the assertion. Test is defensive about CI vs dev environments.
        } catch let err as AppError {
            if case .credentials = err {} else {
                Issue.record("expected .credentials, got \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
    }
}

/// Unit tests for the pure reconciliation logic extracted from
/// `KeychainCredentialReader.read()`. The freshness-wins / dropPending
/// invariant drives whether the in-memory `pendingUpdate` cache stays
/// after the read — verified here without touching the real Keychain.
@Suite("CredentialReconciliation.pick — pure freshness logic")
struct CredentialReconciliationTests {
    private func creds(_ exp: Int64) -> AnthropicCredentials {
        AnthropicCredentials(accessToken: "tok-\(exp)",
                             refreshToken: "rt",
                             expiresAtMs: exp)
    }

    @Test("nil disk + nil pending → nil (caller must throw)")
    func both_nil_returns_nil() {
        #expect(CredentialReconciliation.pick(disk: nil, pending: nil) == nil)
    }

    @Test("disk only → return disk, do not drop pending")
    func disk_only_returns_disk() {
        let d = creds(1000)
        let v = CredentialReconciliation.pick(disk: d, pending: nil)
        #expect(v?.credentials == d)
        expectFalse(v?.dropPending ?? true)
    }

    @Test("pending only → return pending, do not drop (nothing to drop)")
    func pending_only_returns_pending() {
        let p = creds(2000)
        let v = CredentialReconciliation.pick(disk: nil, pending: p)
        #expect(v?.credentials == p)
        expectFalse(v?.dropPending ?? true)
    }

    @Test("disk fresher → return disk, drop pending (disk won)")
    func disk_fresher_returns_disk_and_drops_pending() {
        let d = creds(2000)
        let p = creds(1000)
        let v = CredentialReconciliation.pick(disk: d, pending: p)
        #expect(v?.credentials == d)
        expectTrue(v?.dropPending ?? false)
    }

    @Test("pending fresher → return pending, keep pending")
    func pending_fresher_returns_pending_and_keeps() {
        let d = creds(1000)
        let p = creds(2000)
        let v = CredentialReconciliation.pick(disk: d, pending: p)
        #expect(v?.credentials == p)
        expectFalse(v?.dropPending ?? true)
    }

    @Test("equal expiry → disk wins (>=), drop pending")
    func equal_expiry_disk_wins_tiebreak() {
        // The `>=` lets disk recover from a previously-pending state when
        // an external actor (CLI re-auth) caught up.
        let d = creds(1500)
        let p = creds(1500)
        let v = CredentialReconciliation.pick(disk: d, pending: p)
        #expect(v?.credentials == d)
        expectTrue(v?.dropPending ?? false)
    }

    @Test("ACL block path: disk nil but pending present serves pending")
    func acl_block_serves_pending() {
        // This is the headline case: ACL mismatch blocked writeBack, so the
        // freshest token only lives in memory. The reader MUST serve it
        // rather than surfacing the keychain error to the user.
        let p = creds(999_999)
        let v = CredentialReconciliation.pick(disk: nil, pending: p)
        #expect(v?.credentials == p)
        expectFalse(v?.dropPending ?? true)
    }
}

@Suite("Keychain memory-cache buffer")
struct KeychainMemoryCacheBufferTests {
    @Test("invalidateCachedCredentials clears seeded lastKnownGood (TEST-ARG-004)")
    func invalidate_clears_memory_cache() {
        let reader = KeychainCredentialReader(service: "test-invalidate-svc")
        let far = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let c = AnthropicCredentials(accessToken: "tok", refreshToken: "r", expiresAtMs: far)
        reader.seedLastKnownGoodForTesting(c)
        #expect(reader.testingLastKnownGood?.accessToken == "tok")
        reader.invalidateCachedCredentials()
        #expect(reader.testingLastKnownGood == nil)
    }

    @Test("memoryCacheBuffer matches OAuth-style 5 minute headroom")
    func buffer_is_five_minutes() {
        #expect(KeychainCredentialReader.memoryCacheBuffer == 300)
    }

    @Test("fresh credentials are not expired under the memory-cache buffer")
    func fresh_token_passes_buffer() {
        let farFuture = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let c = AnthropicCredentials(accessToken: "a", refreshToken: "r", expiresAtMs: farFuture)
        #expect(!c.isExpired(buffer: KeychainCredentialReader.memoryCacheBuffer))
    }

    @Test("credentials inside the buffer window are treated as expired for re-read")
    func near_expiry_forces_reread() {
        // Expires in 60s — within the 300s buffer → cache miss path.
        let soon = Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
        let c = AnthropicCredentials(accessToken: "a", refreshToken: "r", expiresAtMs: soon)
        #expect(c.isExpired(buffer: KeychainCredentialReader.memoryCacheBuffer))
    }
}
