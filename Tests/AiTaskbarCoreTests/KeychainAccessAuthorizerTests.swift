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
}
