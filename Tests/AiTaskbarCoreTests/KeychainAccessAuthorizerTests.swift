import Foundation
import Security
import Testing
import AiTaskbarTestSupport
@testable import AiTaskbarCore

/// Exercises the ACL-surgery helpers against a REAL temporary keychain item
/// owned by the test runner. Creating/deleting our own item is silent (the
/// creator is trusted), and none of these helpers call
/// `SecKeychainItemSetAccess`, so no SecurityAgent dialog can appear. The
/// interactive commit path of `authorize(service:)` stays manual-test-only.
@Suite("KeychainAccessAuthorizer ACL surgery", .serialized)
struct KeychainAccessAuthorizerTests {
    /// Unique per-run service name so parallel/aborted runs never collide.
    private static let service = "ai-taskbar-test-\(UUID().uuidString)"

    private func makeTempItem() throws -> (item: SecKeychainItem, cleanup: () -> Void) {
        let add: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "tester",
            kSecValueData as String:   Data("x".utf8),
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        try #require(addStatus == errSecSuccess || addStatus == errSecDuplicateItem)

        var ref: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String:  kSecMatchLimitOne,
            kSecReturnRef as String:   true,
        ]
        try #require(SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess)
        let item = ref as! SecKeychainItem
        let cleanup = {
            let del: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
            ]
            SecItemDelete(del as CFDictionary)
        }
        return (item, cleanup)
    }

    @Test("finds the partition ACL and extends it in memory")
    func extends_partition_list() throws {
        let (item, cleanup) = try makeTempItem()
        defer { cleanup() }

        var accessRef: SecAccess?
        try #require(SecKeychainItemCopyAccess(item, &accessRef) == errSecSuccess)
        let access = try #require(accessRef)

        // Our own fresh item carries a partition ACL on modern macOS.
        let acl = KeychainAccessAuthorizer.findACL(in: access,
                                                   authorization: "ACLAuthorizationPartitionID")
        try #require(acl != nil)

        try KeychainAccessAuthorizer.extendPartitionList(of: access,
                                                         with: "teamid:TESTTEAM01")

        // Re-read the (in-memory) ACL and confirm the partition landed.
        var appsRef: CFArray?
        var descRef: CFString?
        var prompt = SecKeychainPromptSelector()
        try #require(SecACLCopyContents(acl!, &appsRef, &descRef, &prompt) == errSecSuccess)
        let partitions = PartitionListCodec.decode(hexDescription: (descRef as String?) ?? "")
        expectTrue(partitions?.contains("teamid:TESTTEAM01") ?? false)
    }

    @Test("extending twice is idempotent (second call is a no-op)")
    func extend_idempotent() throws {
        let (item, cleanup) = try makeTempItem()
        defer { cleanup() }
        var accessRef: SecAccess?
        try #require(SecKeychainItemCopyAccess(item, &accessRef) == errSecSuccess)
        let access = try #require(accessRef)
        try KeychainAccessAuthorizer.extendPartitionList(of: access, with: "teamid:TESTTEAM01")
        try KeychainAccessAuthorizer.extendPartitionList(of: access, with: "teamid:TESTTEAM01")
        let acl = try #require(KeychainAccessAuthorizer.findACL(
            in: access, authorization: "ACLAuthorizationPartitionID"))
        var appsRef: CFArray?
        var descRef: CFString?
        var prompt = SecKeychainPromptSelector()
        try #require(SecACLCopyContents(acl, &appsRef, &descRef, &prompt) == errSecSuccess)
        let partitions = PartitionListCodec.decode(hexDescription: (descRef as String?) ?? "") ?? []
        #expect(partitions.filter { $0 == "teamid:TESTTEAM01" }.count == 1)
    }

    @Test("adds self to the decrypt ACL without throwing")
    func adds_self_to_decrypt_acl() throws {
        let (item, cleanup) = try makeTempItem()
        defer { cleanup() }
        var accessRef: SecAccess?
        try #require(SecKeychainItemCopyAccess(item, &accessRef) == errSecSuccess)
        let access = try #require(accessRef)
        try KeychainAccessAuthorizer.addSelfToDecryptACL(of: access)
    }

    @Test("authorization commits only the decrypt ACL, leaving partition changes to securityd")
    func native_authorization_preserves_partition_payload() throws {
        let (_, cleanup) = try makeTempItem()
        defer { cleanup() }
        var probes = 0
        var commits = 0
        let outcome = try KeychainAccessAuthorizer.authorize(
            service: Self.service, teamID: "MUSTNOTBEWRITTEN",
            probeRead: { _, _ in
                probes += 1
                return probes > 1
            },
            commitAccess: { _, access in
                commits += 1
                let acl = KeychainAccessAuthorizer.findACL(
                    in: access, authorization: "ACLAuthorizationPartitionID")
                if let acl {
                    var applications: CFArray?
                    var description: CFString?
                    var prompt = SecKeychainPromptSelector()
                    #expect(SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess)
                    let partitions = PartitionListCodec.decode(
                        hexDescription: (description as String?) ?? "") ?? []
                    expectFalse(partitions.contains("teamid:MUSTNOTBEWRITTEN"))
                } else {
                    Issue.record("Temporary item should have a partition ACL")
                }
                return errSecSuccess
            })
        #expect(outcome == .authorized)
        #expect(commits == 1)
        #expect(probes == 2)
    }

    @Test("direct partition edits are rejected even for an unlocked owned item")
    func partition_edit_requires_password_credentials() throws {
        let (item, cleanup) = try makeTempItem()
        defer { cleanup() }
        var accessRef: SecAccess?
        try #require(SecKeychainItemCopyAccess(item, &accessRef) == errSecSuccess)
        let access = try #require(accessRef)
        try KeychainAccessAuthorizer.extendPartitionList(of: access, with: "teamid:TESTONLY")
        let status = KeychainPromptSuppressor.withPromptsSuppressed {
            SecKeychainItemSetAccess(item, access)
        }
        #expect(status == errSecAuthFailed)
    }

    @Test("revalidating an owned decrypt ACL commits without modifying partitions")
    func decrypt_only_commit_succeeds() throws {
        let (item, cleanup) = try makeTempItem()
        defer { cleanup() }
        var accessRef: SecAccess?
        try #require(SecKeychainItemCopyAccess(item, &accessRef) == errSecSuccess)
        let access = try #require(accessRef)
        let prepared = try KeychainAccessAuthorizer.addSelfToDecryptACL(of: access, revalidate: true)
        #expect(prepared)
        let status = KeychainPromptSuppressor.withPromptsSuppressed {
            SecKeychainItemSetAccess(item, access)
        }
        #expect(status == errSecSuccess)
        #expect(KeychainAccessAuthorizer.canReadSilently(Self.service, account: "tester"))
    }

    @Test("revalidation preserves an existing unrestricted decrypt ACL")
    func revalidation_preserves_nil_app_list() throws {
        let (item, cleanup) = try makeTempItem()
        defer { cleanup() }
        var accessRef: SecAccess?
        try #require(SecKeychainItemCopyAccess(item, &accessRef) == errSecSuccess)
        let access = try #require(accessRef)
        let acl = try #require(KeychainAccessAuthorizer.findACL(
            in: access, authorization: "ACLAuthorizationDecrypt"))
        var apps: CFArray?
        var description: CFString?
        var prompt = SecKeychainPromptSelector()
        try #require(SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess)
        let originalPrompt = prompt
        // In-memory fixture only: never write an unrestricted ACL to Keychain.
        try #require(SecACLSetContents(acl, nil, "Preserved label" as CFString, prompt) == errSecSuccess)
        let prepared = try KeychainAccessAuthorizer.addSelfToDecryptACL(of: access, revalidate: true)
        #expect(prepared)
        try #require(SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess)
        expectTrue(apps == nil)
        expectTrue((description as String?) == "Preserved label")
        #expect(prompt == originalPrompt)
    }

    @Test("native authorization cannot report success after cancel, denial or failed verification",
          arguments: [errSecUserCanceled, errSecAuthFailed, errSecParam, errSecSuccess])
    func failed_commit_or_probe_never_authorizes(status: OSStatus) throws {
        let (_, cleanup) = try makeTempItem()
        defer { cleanup() }
        var commits = 0
        do {
            let outcome = try KeychainAccessAuthorizer.authorize(
                service: Self.service, teamID: "TESTTEAM",
                probeRead: { _, _ in false },
                commitAccess: { _, _ in
                    commits += 1
                    return status
                })
            #expect(status == errSecUserCanceled)
            #expect(outcome == .canceled)
        } catch let error as KeychainAccessAuthorizer.AuthorizationFailure {
            #expect(status == errSecAuthFailed)
            #expect(error == .authorizationDenied)
        } catch is AppError {
            expectTrue(status == errSecParam || status == errSecSuccess)
        }
        #expect(commits == 1)
    }

    @Test("unknown authorization tag finds no ACL")
    func unknown_tag() throws {
        let (item, cleanup) = try makeTempItem()
        defer { cleanup() }
        var accessRef: SecAccess?
        try #require(SecKeychainItemCopyAccess(item, &accessRef) == errSecSuccess)
        let access = try #require(accessRef)
        #expect(KeychainAccessAuthorizer.findACL(in: access,
                                                 authorization: "NoSuchAuthorization") == nil)
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
            service: Self.service,
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
            kSecValueData as String:   Data("legacy".utf8),
        ]
        try #require(SecItemAdd(legacyAdd as CFDictionary, nil) == errSecSuccess)

        var probedAccounts: [String?] = []
        let outcome = try KeychainAccessAuthorizer.authorize(
            service: Self.service,
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
            kSecValueData as String:   Data("work".utf8),
        ]
        try #require(SecItemAdd(secondAdd as CFDictionary, nil) == errSecSuccess)

        var probeCalls = 0
        #expect(throws: AppError.self) {
            try KeychainAccessAuthorizer.authorize(
                service: Self.service,
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
            kSecValueData as String:   Data("work".utf8),
        ]
        try #require(SecItemAdd(secondAdd as CFDictionary, nil) == errSecSuccess)

        var probedAccounts: [String?] = []
        let outcome = try KeychainAccessAuthorizer.authorize(
            service: Self.service,
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
                service: Self.service,
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
                service: Self.service,
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
