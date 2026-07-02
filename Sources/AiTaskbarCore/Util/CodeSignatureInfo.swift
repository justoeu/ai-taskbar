import Foundation
import Security

/// Introspects the running binary's code signature so the UI can credit the
/// developer without hardcoding a name. Ad-hoc builds carry no certificate
/// chain, so every accessor degrades to `nil` and the UI simply omits the
/// credit line.
public enum CodeSignatureInfo {
    /// Signing-information dictionary of the running process, or nil when it
    /// can't be obtained.
    private static func signingInfo() -> [String: Any]? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess,
              let code = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef else { return nil }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess else {
            return nil
        }
        return infoRef as? [String: Any]
    }

    /// Common Name of the leaf signing certificate of the current process,
    /// e.g. `"Developer ID Application: Valmir Robson Justo (5HHL78743R)"`.
    /// `nil` for ad-hoc/unsigned binaries (they have no cert chain).
    public static func signingCertificateCommonName() -> String? {
        guard let info = signingInfo(),
              let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return nil }
        var cn: CFString?
        guard SecCertificateCopyCommonName(leaf, &cn) == errSecSuccess,
              let cn else { return nil }
        return cn as String
    }

    /// Team identifier of the running binary's signature (e.g. "5HHL78743R"),
    /// or nil for ad-hoc/unsigned builds. Used to compose the Keychain
    /// partition-list remediation command with the right `teamid:` entry.
    public static func currentTeamID() -> String? {
        guard let info = signingInfo(),
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team
    }

    /// Human name extracted from a signing-cert Common Name.
    ///
    /// `"Developer ID Application: Valmir Robson Justo (5HHL78743R)"`
    /// → `"Valmir Robson Justo"`. Works for any `<role>: <name> (<team>)`
    /// shape (Apple Development, Mac Developer, …). The trailing team
    /// parenthetical is stripped only when it looks like a 10-char team ID,
    /// so a name that legitimately contains parentheses survives.
    public static func developerName(fromCommonName cn: String) -> String? {
        var name = cn
        if let colon = name.range(of: ": ") {
            name = String(name[colon.upperBound...])
        }
        if let open = name.range(of: " (", options: .backwards),
           name.hasSuffix(")") {
            let team = name[open.upperBound..<name.index(before: name.endIndex)]
            if team.count == 10, team.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                name = String(name[..<open.lowerBound])
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Convenience: developer name of the running binary, or `nil` when
    /// unsigned/ad-hoc.
    public static func currentDeveloperName() -> String? {
        signingCertificateCommonName().flatMap { developerName(fromCommonName: $0) }
    }
}
