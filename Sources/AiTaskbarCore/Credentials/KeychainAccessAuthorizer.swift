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

    /// Shared with `SecurityToolCredentialReader.decodeOutput`; one hex decoder
    /// for the Credentials directory.
    internal static func dataFromHex(_ hex: String) -> Data? {
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
/// A user-initiated exact-item read lets SecurityAgent obtain consent and
/// securityd update the trusted-app and partition ACLs. An ACL commit alone
/// does NOT extend partitions on the foreign Claude item. The app neither
/// edits those ACLs nor receives the Keychain password. Read data is discarded;
/// the normal credential reader reconciles its own fresh copy afterward.
/// Success requires a subsequent silent read of the SAME item reference.
public enum KeychainAccessAuthorizer {
    /// Human-readable outcome distinguishing "user changed their mind" from
    /// real failures, so the UI can dismiss quietly on cancel.
    public enum Outcome: Equatable {
        case authorized
        case canceled
    }

    /// An authentication denial is not proof of an incorrect password.
    /// securityd also returns it for a prohibited ACL edit without showing
    /// any password dialog. Never diagnose password mismatch from this code.
    public enum AuthorizationFailure: Error, Sendable, Equatable, LocalizedError {
        case authorizationDenied
        case permissionNotPersistent

        public var errorDescription: String? {
            switch self {
            case .permissionNotPersistent:
                return "macOS allowed access, but silent verification failed. Try again and choose Always Allow if offered. Managed Keychain policies may prevent persistent access."
            case .authorizationDenied:
                return "macOS could not authorize this app to access the Claude Code Keychain item (OSStatus -25293)."
            }
        }
    }

    /// UIFail probe: `true` when this binary can already DECRYPT the item's
    /// data with no SecurityAgent prompt — i.e. the decrypt ACL + partition
    /// list already grant access. `kSecUseAuthenticationUIFail` guarantees we
    /// fast-fail (`errSecInteractionNotAllowed`) instead of ever prompting, so
    /// this is safe to call from any context. See `KeychainCredentialReader`
    /// for why the deprecated UIFail key is deliberate for these plain
    /// generic-password items.
    public static func canReadSilently(_ service: String, account: String? = nil) -> Bool {
        var result: CFTypeRef?
        var query: [String: Any] = [
            kSecClass as String:               kSecClassGenericPassword,
            kSecAttrService as String:         service,
            kSecMatchLimit as String:          kSecMatchLimitOne,
            kSecReturnData as String:          true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        // UIFail alone does NOT silence the partition-list password dialog —
        // only the trusted-app Allow/Deny one. The suppressor guarantees the
        // probe is truly silent (see KeychainPromptSuppressor).
        return KeychainPromptSuppressor.withPromptsSuppressed {
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        }
    }

    /// Called only by the user's Authorize action, never by scheduled refresh.
    public static func authorize(service: String, account: String? = nil) throws -> Outcome {
        try authorize(service: service, account: account,
                      teamID: CodeSignatureInfo.currentTeamID())
    }

    /// Internal synchronous seams keep automated tests from presenting UI.
    internal static func authorize(service: String,
                                 searchList: [SecKeychain]? = nil,
                                 account: String? = nil,
                                 teamID: String? = CodeSignatureInfo.currentTeamID(),
                                 probeRead: ((String, String?) -> Bool)? = nil,
                                 readItem: (CFDictionary) -> OSStatus = copyItemData,
                                 didAuthorize: (TargetIdentity) -> Void = { _ in }) throws -> Outcome {
        let target = try selectedTarget(service: service, account: account, searchList: searchList)

        guard let teamID, !teamID.isEmpty else {
            throw AppError.credentials(
                "Persistent Keychain authorization requires a stable Developer ID signature. Install or build a signed AI Taskbar app and try again.")
        }

        func probe() -> Bool {
            if let probeRead { return probeRead(service, target.account) }
            return KeychainPromptSuppressor.withPromptsSuppressed {
                readItem(itemReadQuery(target.item, service: service, account: target.account,
                                       searchList: searchList, interactive: false)) == errSecSuccess
            }
        }
        if probe() {
            didAuthorize(target.identity)
            return .authorized
        }

        // One intentional UI window, locked against concurrent silent reads.
        // Do not use service-only MatchOne: that can authorize a legacy sibling.
        let status = KeychainPromptSuppressor.withPromptsAllowed {
            readItem(itemReadQuery(target.item, service: service, account: target.account,
                                   searchList: searchList, interactive: true))
        }
        if status == errSecUserCanceled { return .canceled }
        if let failure = authorizationFailure(forCommitStatus: status) { throw failure }
        try check(status, "authorize read")
        guard probe() else { throw AuthorizationFailure.permissionNotPersistent }
        didAuthorize(target.identity)
        return .authorized
    }

    internal static func itemReadQuery(_ item: SecKeychainItem,
                                       service: String, account: String?,
                                       searchList: [SecKeychain]?,
                                       interactive: Bool) -> CFDictionary {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account ?? "",
            kSecMatchItemList as String: [item] as CFArray,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: interactive
                ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail,
        ]
        if let searchList { query[kSecMatchSearchList as String] = searchList }
        return query as CFDictionary
    }

    private static func copyItemData(_ query: CFDictionary) -> OSStatus {
        var data: CFTypeRef?
        // Never return, log, cache or persist these bytes from the authorizer.
        return SecItemCopyMatching(query, &data)
    }

    /// Pure classification seam for the user-initiated read. Keeping this
    /// separate from `check` preserves the existing scheduled-read ACL error
    /// classification without attributing an unproven cause to the denial.
    internal static func authorizationFailure(
        forCommitStatus status: OSStatus
    ) -> AuthorizationFailure? {
        status == errSecAuthFailed ? .authorizationDenied : nil
    }

    internal struct TargetIdentity: Sendable, Equatable {
        let persistentRef: Data
        let account: String?
    }

    private struct AuthorizationTarget {
        let identity: TargetIdentity
        let item: SecKeychainItem
        var account: String? { identity.account }
    }

    internal static func resolveIdentity(service: String, account: String?,
                                          searchList: [SecKeychain]? = nil) throws -> TargetIdentity {
        try selectedTarget(service: service, account: account, searchList: searchList).identity
    }

    private static func selectedTarget(service: String, account: String?,
                                        searchList: [SecKeychain]?) throws -> AuthorizationTarget {
        try authorizationTarget(from: candidateMatches(service: service, searchList: searchList), account: account)
    }

    internal static func candidateIdentities(service: String,
                                            searchList: [SecKeychain]?) throws -> [TargetIdentity] {
        try candidateMatches(service: service, searchList: searchList).compactMap { match in
            guard let persistent = match[kSecValuePersistentRef as String] as? Data else { return nil }
            return TargetIdentity(persistentRef: persistent, account: match[kSecAttrAccount as String] as? String)
        }
    }

    private static func candidateMatches(service: String,
                                         searchList: [SecKeychain]?) throws -> [[String: Any]] {
        var result: CFTypeRef?
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
            kSecReturnPersistentRef as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let searchList { query[kSecMatchSearchList as String] = searchList }
        let status = KeychainPromptSuppressor.withPromptsSuppressed {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess, let matches = result as? [[String: Any]] else {
            throw KeychainCredentialReader.errorFor(status: status, op: "locate credential")
        }
        return matches
    }

    private static func authorizationTarget(
        from matches: [[String: Any]],
        account requestedAccount: String?
    ) throws -> AuthorizationTarget {
        let all = matches.compactMap { match -> AuthorizationTarget? in
            guard let ref = match[kSecValueRef as String],
                  let persistent = match[kSecValuePersistentRef as String] as? Data else { return nil }
            return AuthorizationTarget(
                identity: TargetIdentity(persistentRef: persistent,
                                         account: match[kSecAttrAccount as String] as? String),
                item: ref as! SecKeychainItem)
        }
        if let requestedAccount {
            let selected = all.filter { $0.account == requestedAccount }
            guard selected.count == 1, let target = selected.first else {
                throw AppError.credentials(
                    "Keychain item has no entry for the configured account '\(requestedAccount)'")
            }
            return target
        }
        let accountBearing = all.filter { !($0.account ?? "").isEmpty }
        let candidates = accountBearing.isEmpty ? all : accountBearing
        guard candidates.count == 1 else {
            if candidates.isEmpty {
                throw AppError.credentials("Keychain item has no usable item references")
            }
            throw AppError.credentials(
                "Multiple Claude Code Keychain accounts were found. Set keychain_account in the Anthropic settings before authorizing.")
        }
        return candidates[0]
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
