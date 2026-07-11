import Foundation
import Security

/// Hex ↔ partition-ID-list codec for the Keychain "PartitionID" ACL.
///
/// macOS (since Sierra) stores each item's partition list as the
/// *description* field of an ACL entry whose authorization tag is
/// `ACLAuthorizationPartitionID`. The description is a hex-encoded XML
/// property list of the shape `{"Partitions": ["apple:", "teamid:XYZ", …]}`.
/// Pure functions so the round-trip is unit-testable without a keychain.
public enum PartitionListCodec {
    /// Decodes the hex-encoded plist into its partition IDs.
    /// Returns nil when the payload isn't hex or isn't the expected plist.
    public static func decode(hexDescription: String) -> [String]? {
        guard let data = dataFromHex(hexDescription) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let partitions = plist["Partitions"] as? [String] else { return nil }
        return partitions
    }

    /// Encodes partition IDs back into the hex-plist wire form.
    public static func encode(partitions: [String]) -> String? {
        let plist: [String: Any] = ["Partitions": partitions]
        guard let data = try? PropertyListSerialization.data(
                  fromPropertyList: plist, format: .xml, options: 0) else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// Appends `partition` unless already present (order-preserving).
    public static func adding(_ partition: String, to partitions: [String]) -> [String] {
        partitions.contains(partition) ? partitions : partitions + [partition]
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else {
                return nil
            }
            data.append(byte)
            index += 2
        }
        return data
    }
}

/// One-time, in-app authorization of this binary against another app's
/// keychain item (the Claude Code CLI's `Claude Code-credentials`).
///
/// Two ACL layers gate silent reads of a foreign generic password:
/// 1. the trusted-application list on the decrypt ACL ("Always Allow"), and
/// 2. the partition list — signing identities allowed to USE that ACL.
/// The SecurityAgent "Always Allow" button only edits layer 1, which is why
/// users kept being re-prompted forever. This authorizer edits BOTH layers,
/// then commits via `SecKeychainItemSetAccess` — the commit is what makes the
/// system show ONE native password dialog; after it, reads are silent for
/// every future launch and update of this (stable Developer ID) identity.
///
/// Uses the legacy `SecKeychainItem*`/`SecACL*` APIs deliberately: they are
/// deprecated but remain the ONLY route to classic file-keychain ACLs (the
/// modern SecItem layer cannot express partition lists). Must be called from
/// a user-initiated action — the commit blocks on SecurityAgent UI.
public enum KeychainAccessAuthorizer {
    /// Human-readable outcome distinguishing "user changed their mind" from
    /// real failures, so the UI can dismiss quietly on cancel.
    public enum Outcome: Equatable {
        case authorized
        case canceled
    }

    /// UIFail probe: `true` when this binary can already DECRYPT the item's
    /// data with no SecurityAgent prompt — i.e. the decrypt ACL + partition
    /// list already grant access. `kSecUseAuthenticationUIFail` guarantees we
    /// fast-fail (`errSecInteractionNotAllowed`) instead of ever prompting, so
    /// this is safe to call from any context. See `KeychainCredentialReader`
    /// for why the deprecated UIFail key is deliberate for these plain
    /// generic-password items.
    public static func canReadSilently(_ service: String) -> Bool {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            kSecMatchLimit as String:          kSecMatchLimitOne,
            kSecReturnData as String:          true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        // UIFail alone does NOT silence the partition-list password dialog —
        // only the trusted-app Allow/Deny one. The suppressor guarantees the
        // probe is truly silent (see KeychainPromptSuppressor).
        return KeychainPromptSuppressor.withPromptsSuppressed {
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        }
    }

    /// - Parameter probeRead: injection seam for tests. Production callers use
    ///   the default (`canReadSilently`); a test can force the short-circuit
    ///   or the full ACL path deterministically without a real Keychain.
    public static func authorize(service: String,
                                 probeRead: (String) -> Bool = KeychainAccessAuthorizer.canReadSilently) throws -> Outcome {
        // 0. Idempotency gate. If the item already decrypts silently, both ACL
        //    layers (trusted-app list + partition list) already admit this
        //    binary. Committing again via `SecKeychainItemSetAccess` would
        //    re-trigger the login-password dialog (ChangeACL always prompts)
        //    AND append a duplicate trusted-app entry — the exact pileup that
        //    left dozens of dead ACL records in the field. Return authorized
        //    with zero side effects.
        if probeRead(service) { return .authorized }

        // 1. Item reference. Fetching the ref (not the data) needs no ACL
        //    authorization, so UIFail cannot spuriously prompt here.
        var itemRef: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            kSecMatchLimit as String:          kSecMatchLimitOne,
            kSecReturnRef as String:           true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        let findStatus = SecItemCopyMatching(query as CFDictionary, &itemRef)
        guard findStatus == errSecSuccess, let ref = itemRef else {
            throw AppError.credentials(
                "Keychain item '\(service)' not found (OSStatus \(findStatus)). Run Claude Code at least once.")
        }
        let item = ref as! SecKeychainItem  // kSecReturnRef for genp IS a SecKeychainItem

        // 2. Current access object.
        var accessRef: SecAccess?
        try check(SecKeychainItemCopyAccess(item, &accessRef), "copy access")
        guard let access = accessRef else {
            throw AppError.credentials("Keychain item has no access object")
        }

        // 3. Extend the partition list with this binary's teamid (or
        //    "unsigned:" for ad-hoc dev builds).
        let myPartition = CodeSignatureInfo.currentTeamID().map { "teamid:\($0)" } ?? "unsigned:"
        try extendPartitionList(of: access, with: myPartition)

        // 4. Add ourselves to the decrypt ACL's trusted apps so no
        //    Allow/Deny prompt remains after the partition gate opens.
        try addSelfToDecryptACL(of: access)

        // 5. Commit. THIS is the single native password dialog.
        let commit = SecKeychainItemSetAccess(item, access)
        if commit == errSecUserCanceled {
            return .canceled
        }
        try check(commit, "commit access")
        return .authorized
    }

    // MARK: - ACL surgery

    internal static func extendPartitionList(of access: SecAccess,
                                            with partition: String) throws {
        guard let acl = findACL(in: access, authorization: "ACLAuthorizationPartitionID") else {
            // Pre-Sierra item without a partition ACL: nothing gates the
            // trusted-app list, so step 4 alone suffices.
            return
        }
        var appsRef: CFArray?
        var descRef: CFString?
        var prompt = SecKeychainPromptSelector()
        try check(SecACLCopyContents(acl, &appsRef, &descRef, &prompt), "read partition ACL")
        let hex = (descRef as String?) ?? ""
        guard let current = PartitionListCodec.decode(hexDescription: hex) else {
            throw AppError.credentials("unrecognized partition-list format on '\(hex.prefix(32))…'")
        }
        let updated = PartitionListCodec.adding(partition, to: current)
        guard updated != current else { return }
        guard let newHex = PartitionListCodec.encode(partitions: updated) else {
            throw AppError.credentials("failed to re-encode partition list")
        }
        try check(SecACLSetContents(acl, appsRef, newHex as CFString, prompt),
                  "write partition ACL")
    }

    internal static func addSelfToDecryptACL(of access: SecAccess) throws {
        guard let acl = findACL(in: access, authorization: "ACLAuthorizationDecrypt") else {
            return
        }
        var appsRef: CFArray?
        var descRef: CFString?
        var prompt = SecKeychainPromptSelector()
        try check(SecACLCopyContents(acl, &appsRef, &descRef, &prompt), "read decrypt ACL")
        var selfRef: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath(nil, &selfRef), "identify self")
        guard let me = selfRef else {
            throw AppError.credentials("cannot build trusted-application ref for this app")
        }
        // nil app list = "all applications allowed"; adding ourselves to it
        // would RESTRICT access, so leave it untouched.
        guard let apps = appsRef as? [SecTrustedApplication] else { return }
        let updated = apps + [me]
        try check(SecACLSetContents(acl, updated as CFArray,
                                    descRef ?? ("" as CFString), prompt),
                  "write decrypt ACL")
    }

    /// Finds the first ACL entry carrying `authorization` (compared as
    /// strings, so we don't depend on which kSecACLAuthorization* constants
    /// the SDK exposes).
    internal static func findACL(in access: SecAccess, authorization: String) -> SecACL? {
        var aclsRef: CFArray?
        guard SecAccessCopyACLList(access, &aclsRef) == errSecSuccess,
              let acls = aclsRef as? [SecACL] else { return nil }
        for acl in acls {
            guard let auths = SecACLCopyAuthorizations(acl) as? [Any] else { continue }
            if auths.contains(where: { String(describing: $0) == authorization }) {
                return acl
            }
        }
        return nil
    }

    private static func check(_ status: OSStatus, _ op: String) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw AppError.credentials("keychain authorization failed (\(op)): \(detail)")
        }
    }
}

public extension AppError {
    /// True when the error is the Keychain ACL/partition-list block that the
    /// in-app "Authorize access" flow can fix. Matches both fast-fail codes:
    /// `errSecInteractionNotAllowed` (trusted-app confirmation suppressed by
    /// UIFail) and `errSecAuthFailed` (partition-list password dialog blocked
    /// by `KeychainPromptSuppressor`).
    var isKeychainACLBlocked: Bool {
        if case .credentials(let m) = self,
           m.contains("errSecInteractionNotAllowed") || m.contains("errSecAuthFailed") {
            return true
        }
        return false
    }
}
