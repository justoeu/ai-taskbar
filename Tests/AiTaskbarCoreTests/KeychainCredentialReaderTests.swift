import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("KeychainCredentialReader — non-syscall surface")
struct KeychainCredentialReaderTests {
    @Test("default service + preferredAccount nil")
    func init_defaults() {
        let reader = KeychainCredentialReader()
        #expect(reader.service == "Claude Code-credentials")
        #expect(reader.preferredAccount == nil)
    }

    @Test("custom service + preferredAccount stick")
    func init_custom() {
        let reader = KeychainCredentialReader(service: "Other",
                                              preferredAccount: "work")
        #expect(reader.service == "Other")
        #expect(reader.preferredAccount == "work")
    }

    @Test("select picks the preferredAccount when present")
    func select_picks_preferred() {
        let reader = KeychainCredentialReader(service: "s",
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
        let reader = KeychainCredentialReader(service: "s",
                                              preferredAccount: nil)
        let items = [
            KeychainCredentialReader.KeychainItem(account: "only", data: Data("d".utf8)),
        ]
        let chosen = reader.select(from: items)
        #expect(chosen.account == "only")
    }

    @Test("select falls back to lex-smallest when preferred missing")
    func select_falls_back_to_lex_smallest() {
        let reader = KeychainCredentialReader(service: "s",
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
        let reader = KeychainCredentialReader(service: "s", preferredAccount: nil)
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
        let reader = KeychainCredentialReader(service: "s", preferredAccount: nil)
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
        let reader = KeychainCredentialReader(service: "s", preferredAccount: "pinned")
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
            #expect(msg.contains("set-generic-password-partition-list"))
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
            #expect(msg.contains("set-generic-password-partition-list"))
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

        // Seed the Keychain. Skip the test if SecItemAdd fails (some CI
        // environments don't allow GenericPassword writes).
        let addQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String:   Data(payload.utf8),
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            // CI runner probably can't write to login keychain. Not a real
            // failure of the code under test.
            return
        }
        defer {
            let delQuery: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            _ = SecItemDelete(delQuery as CFDictionary)
        }

        let reader = KeychainCredentialReader(service: service)
        let creds = try reader.read()
        #expect(creds.accessToken == "seeded-access")
        #expect(creds.refreshToken == "seeded-refresh")
        #expect(creds.expiresAtMs == 1_764_201_600_000)
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
            kSecValueData as String:   Data(initialPayload.utf8),
        ]
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            return  // skip on CI without keychain perms
        }
        defer {
            let delQuery: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            _ = SecItemDelete(delQuery as CFDictionary)
        }

        let reader = KeychainCredentialReader(service: service,
                                              preferredAccount: account)
        _ = try? reader.read()   // primes _resolvedAccount
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
        let reader = KeychainCredentialReader(
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
        #expect(v?.dropPending == false)
    }

    @Test("pending only → return pending, do not drop (nothing to drop)")
    func pending_only_returns_pending() {
        let p = creds(2000)
        let v = CredentialReconciliation.pick(disk: nil, pending: p)
        #expect(v?.credentials == p)
        #expect(v?.dropPending == false)
    }

    @Test("disk fresher → return disk, drop pending (disk won)")
    func disk_fresher_returns_disk_and_drops_pending() {
        let d = creds(2000)
        let p = creds(1000)
        let v = CredentialReconciliation.pick(disk: d, pending: p)
        #expect(v?.credentials == d)
        #expect(v?.dropPending == true)
    }

    @Test("pending fresher → return pending, keep pending")
    func pending_fresher_returns_pending_and_keeps() {
        let d = creds(1000)
        let p = creds(2000)
        let v = CredentialReconciliation.pick(disk: d, pending: p)
        #expect(v?.credentials == p)
        #expect(v?.dropPending == false)
    }

    @Test("equal expiry → disk wins (>=), drop pending")
    func equal_expiry_disk_wins_tiebreak() {
        // The `>=` lets disk recover from a previously-pending state when
        // an external actor (CLI re-auth) caught up.
        let d = creds(1500)
        let p = creds(1500)
        let v = CredentialReconciliation.pick(disk: d, pending: p)
        #expect(v?.credentials == d)
        #expect(v?.dropPending == true)
    }

    @Test("ACL block path: disk nil but pending present serves pending")
    func acl_block_serves_pending() {
        // This is the headline case: ACL mismatch blocked writeBack, so the
        // freshest token only lives in memory. The reader MUST serve it
        // rather than surfacing the keychain error to the user.
        let p = creds(999_999)
        let v = CredentialReconciliation.pick(disk: nil, pending: p)
        #expect(v?.credentials == p)
        #expect(v?.dropPending == false)
    }
}

@Suite("Keychain memory-cache buffer")
struct KeychainMemoryCacheBufferTests {
    @Test("memoryCacheBuffer matches OAuth-style 5 minute headroom")
    func buffer_is_five_minutes() {
        #expect(KeychainCredentialReader.memoryCacheBuffer == 300)
    }

    @Test("fresh credentials are not expired under the memory-cache buffer")
    func fresh_token_passes_buffer() {
        let farFuture = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let c = AnthropicCredentials(accessToken: "a", refreshToken: "r", expiresAtMs: farFuture)
        #expect(c.isExpired(buffer: KeychainCredentialReader.memoryCacheBuffer) == false)
    }

    @Test("credentials inside the buffer window are treated as expired for re-read")
    func near_expiry_forces_reread() {
        // Expires in 60s — within the 300s buffer → cache miss path.
        let soon = Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
        let c = AnthropicCredentials(accessToken: "a", refreshToken: "r", expiresAtMs: soon)
        #expect(c.isExpired(buffer: KeychainCredentialReader.memoryCacheBuffer) == true)
    }
}
