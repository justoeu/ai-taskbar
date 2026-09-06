import Foundation
import Security
import Testing
import AiTaskbarTestSupport
@testable import AiTaskbarCore

/// Exercises the ACL-surgery helpers against a REAL temporary keychain item
/// owned by the test runner. Creating/deleting our own item is silent (the
/// creator is trusted), and none of these helpers call
/// `SecKeychainItemSetAccess`, so no SecurityAgent dialog can appear. The
/// interactive read path of `authorize(service:)` stays manual-test-only.
@Suite("KeychainAccessAuthorizer exact-item authorization", .serialized)
struct KeychainAccessAuthorizerTests {
    private let keychain: TemporaryKeychain
    init() throws { keychain = try TemporaryKeychain() }
    @Test("authorization reads exactly one selected item and verifies silently")
    func exact_item_native_read() throws {
        let (item, cleanup) = try makeTempItem()
        defer { cleanup() }
        var calls = 0
        let outcome = try KeychainAccessAuthorizer.authorize(
            service: Self.service, searchList: [keychain.reference], teamID: "TESTTEAM",
            readItem: { query in
                calls += 1
                let q = query as NSDictionary
                let refs = q[kSecMatchItemList] as? [SecKeychainItem] ?? []
                #expect(refs.count == 1)
                if let selected = refs.first { expectTrue(CFEqual(selected, item)) }
                expectTrue(q[kSecReturnData] as? Bool == true)
                let expected = calls == 2 ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
                expectTrue(q[kSecUseAuthenticationUI] as? String == expected as String)
                expectTrue(KeychainPromptSuppressor.testingInteractiveHold == (calls == 2))
                return calls == 1 ? errSecAuthFailed : errSecSuccess
            })
        #expect(outcome == .authorized)
        #expect(calls == 3)
    }

    /// Unique per-run service name so parallel/aborted runs never collide.
    private static let service = "ai-taskbar-test-\(UUID().uuidString)"

    private func makeTempItem() throws -> (item: SecKeychainItem, cleanup: () -> Void) {
        let add: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "tester",
            kSecUseKeychain as String: keychain.reference,
            kSecValueData as String:   Data("x".utf8),
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        try #require(addStatus == errSecSuccess || addStatus == errSecDuplicateItem)

        var ref: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchSearchList as String: [keychain.reference],
            kSecMatchLimit as String:  kSecMatchLimitOne,
            kSecReturnRef as String:   true,
        ]
        try #require(SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess)
        let item = ref as! SecKeychainItem
        let cleanup = {
            let del: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecMatchSearchList as String: [keychain.reference],
                kSecAttrService as String: Self.service,
            ]
            SecItemDelete(del as CFDictionary)
        }
        return (item, cleanup)
    }

    @Test("native authorization cannot report success after cancel, denial or failed verification",
          arguments: [errSecUserCanceled, errSecAuthFailed, errSecParam, errSecSuccess])
    func failed_commit_or_probe_never_authorizes(status: OSStatus) throws {
        let (_, cleanup) = try makeTempItem()
        defer { cleanup() }
        var commits = 0
        do {
            let outcome = try KeychainAccessAuthorizer.authorize(
                service: Self.service, searchList: [keychain.reference], teamID: "TESTTEAM",
                probeRead: { _, _ in false },
                readItem: { _ in
                    commits += 1
                    return status
                })
            #expect(status == errSecUserCanceled)
            #expect(outcome == .canceled)
        } catch let error as KeychainAccessAuthorizer.AuthorizationFailure {
            if status == errSecSuccess {
                #expect(error == .permissionNotPersistent)
            } else {
                #expect(status == errSecAuthFailed)
                #expect(error == .authorizationDenied)
            }
        } catch is AppError {
            #expect(status == errSecParam)
        }
        #expect(commits == 1)
    }

    @Test("authorize on a missing service throws credentials error")
    func missing_service_throws() {
        #expect(throws: AppError.self) {
            try KeychainAccessAuthorizer.authorize(service: "ai-taskbar-definitely-missing-\(UUID())")
        }
    }

    @Test("authorize short-circuits each readable item without committing")
    func idempotent_when_already_readable() throws {
        let (_, cleanup) = try makeTempItem()
        defer { cleanup() }
        let outcome = try KeychainAccessAuthorizer.authorize(
            service: Self.service, searchList: [keychain.reference],
            teamID: "TESTTEAM",
            probeRead: { _, _ in true })
        #expect(outcome == .authorized)
    }

    @Test("authorize prefers account-bearing item over legacy sibling")
    func prefers_account_item_over_legacy() throws {
        let (_, cleanup) = try makeTempItem()
        defer { cleanup() }
        let legacyAdd: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecUseKeychain as String: keychain.reference,
            kSecValueData as String:   Data("legacy".utf8),
        ]
        try #require(SecItemAdd(legacyAdd as CFDictionary, nil) == errSecSuccess)

        var probedAccounts: [String?] = []
        let outcome = try KeychainAccessAuthorizer.authorize(
            service: Self.service, searchList: [keychain.reference],
            teamID: "TESTTEAM",
            probeRead: { _, account in
                probedAccounts.append(account)
                return true
            })

        #expect(outcome == .authorized)
        #expect(probedAccounts.count == 1)
        #expect(probedAccounts[0] == "tester")
    }

    @Test("authorize refuses to guess between multiple unresolved accounts")
    func refuses_ambiguous_accounts() throws {
        let (_, cleanup) = try makeTempItem()
        defer { cleanup() }
        let secondDelete: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "work@example.com",
        ]
        _ = SecItemDelete(secondDelete as CFDictionary)
        defer { _ = SecItemDelete(secondDelete as CFDictionary) }
        let secondAdd: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "work@example.com",
            kSecUseKeychain as String: keychain.reference,
            kSecValueData as String:   Data("work".utf8),
        ]
        try #require(SecItemAdd(secondAdd as CFDictionary, nil) == errSecSuccess)

        var probeCalls = 0
        #expect(throws: AppError.self) {
            try KeychainAccessAuthorizer.authorize(
                service: Self.service, searchList: [keychain.reference],
                teamID: "TESTTEAM",
                probeRead: { _, _ in
                    probeCalls += 1
                    return true
                })
        }

        #expect(probeCalls == 0)
    }

    @Test("authorize limits a multi-account service to the preferred account")
    func authorizes_only_preferred_account() throws {
        let (_, cleanup) = try makeTempItem()
        defer { cleanup() }
        let secondDelete: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "work@example.com",
        ]
        _ = SecItemDelete(secondDelete as CFDictionary)
        defer { _ = SecItemDelete(secondDelete as CFDictionary) }
        let secondAdd: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "work@example.com",
            kSecUseKeychain as String: keychain.reference,
            kSecValueData as String:   Data("work".utf8),
        ]
        try #require(SecItemAdd(secondAdd as CFDictionary, nil) == errSecSuccess)

        var probedAccounts: [String?] = []
        let outcome = try KeychainAccessAuthorizer.authorize(
            service: Self.service, searchList: [keychain.reference],
            account: "work@example.com",
            teamID: "TESTTEAM",
            probeRead: { _, account in
                probedAccounts.append(account)
                return true
            })

        #expect(outcome == .authorized)
        #expect(probedAccounts == ["work@example.com"])
    }

    @Test("blocked authorization fails closed without a stable Team ID")
    func unsigned_authorization_fails_closed() throws {
        let (_, cleanup) = try makeTempItem()
        defer { cleanup() }

        #expect(throws: AppError.self) {
            try KeychainAccessAuthorizer.authorize(
                service: Self.service, searchList: [keychain.reference],
                teamID: nil,
                probeRead: { _, _ in false })
        }
    }

    @Test("readable item still fails durable authorization without a Team ID")
    func unsigned_readable_item_fails_closed() throws {
        let (_, cleanup) = try makeTempItem()
        defer { cleanup() }

        #expect(throws: AppError.self) {
            try KeychainAccessAuthorizer.authorize(
                service: Self.service, searchList: [keychain.reference],
                teamID: nil,
                probeRead: { _, _ in true })
        }
    }

    @Test("authorize proceeds past the gate when the probe says access is blocked")
    func proceeds_when_probe_blocked() {
        // probeRead == false forces the real ACL path; against a missing
        // service that path must fail (item-not-found) rather than silently
        // returning .authorized.
        #expect(throws: AppError.self) {
            try KeychainAccessAuthorizer.authorize(
                service: "ai-taskbar-definitely-missing-\(UUID())",
                probeRead: { _, _ in false })
        }
    }

    @Test("interactive ACL denial does not diagnose an incorrect password")
    func commit_denial_is_typed() throws {
        let failure = try #require(
            KeychainAccessAuthorizer.authorizationFailure(forCommitStatus: errSecAuthFailed)
        )

        #expect(failure == .authorizationDenied)
        expectTrue(
            KeychainAccessAuthorizer.authorizationFailure(forCommitStatus: errSecSuccess) == nil
        )
    }
}
