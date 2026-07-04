import Foundation
import Security
import Testing
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
        #expect(partitions?.contains("teamid:TESTTEAM01") == true)
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

    @Test("authorize short-circuits to .authorized when the item already reads silently")
    func idempotent_when_already_readable() throws {
        // probeRead == true means the ACL/partition list already admit us:
        // authorize must NOT touch SecKeychainItemSetAccess (no prompt, no
        // duplicate ACL entry). It returns .authorized even for a service that
        // doesn't exist, proving no real Keychain lookup happened.
        let outcome = try KeychainAccessAuthorizer.authorize(
            service: "ai-taskbar-definitely-missing-\(UUID())",
            probeRead: { _ in true })
        #expect(outcome == .authorized)
    }

    @Test("authorize proceeds past the gate when the probe says access is blocked")
    func proceeds_when_probe_blocked() {
        // probeRead == false forces the real ACL path; against a missing
        // service that path must fail (item-not-found) rather than silently
        // returning .authorized.
        #expect(throws: AppError.self) {
            try KeychainAccessAuthorizer.authorize(
                service: "ai-taskbar-definitely-missing-\(UUID())",
                probeRead: { _ in false })
        }
    }
}
