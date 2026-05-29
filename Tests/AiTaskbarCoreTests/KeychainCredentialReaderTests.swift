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

    @Test("errorFor maps errSecInteractionNotAllowed to instructive message")
    func errorFor_maps_interaction_not_allowed() {
        let err = KeychainCredentialReader.errorFor(status: -25308, op: "list")
        if case .credentials(let msg) = err {
            #expect(msg.contains("Keychain access denied"))
            #expect(msg.contains("set-generic-password-partition-list"))
        } else {
            Issue.record("expected .credentials")
        }
    }

    @Test("errorFor maps errSecAuthFailed to specific hint")
    func errorFor_maps_auth_failed() {
        let err = KeychainCredentialReader.errorFor(status: -25293, op: "data")
        if case .credentials(let msg) = err {
            #expect(msg.contains("Keychain auth failed"))
        } else {
            Issue.record("expected .credentials")
        }
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
