import Foundation
import Security
import os

/// Outcome of looking for the Muse CLI login, without ever logging the
/// token itself (`docs/SDD-meta-muse.md` §7).
public enum MetaLoginResolution: Equatable, Sendable {
    /// A device-code (`dca:`) access token. Never persisted or logged.
    case token(String)
    /// The Keychain item exists but its ACL refuses this binary. Prompt-free
    /// by design: the caller degrades instead of asking for a password.
    case keychainBlocked
    /// No login anywhere: the user has not run `muse login`.
    case missing
    /// Something unexpected (unrecognized payload, unexpected OSStatus).
    case unavailable(String)
}

/// Raw result of the Keychain read seam.
public enum MetaKeychainRead: Equatable, Sendable {
    case found(Data)
    case blocked
    case missing
    case failed(OSStatus)
}

/// Settings-facing login state: no token ever crosses this boundary.
public enum MetaLoginDetection: Equatable, Sendable {
    case detected
    /// Only the ACL statuses (-25308/-25293) earn this case (SDD §7.2).
    case keychainBlocked
    case missing
    /// Any other Keychain failure: access is unavailable, but calling it
    /// "blocked" or "missing" would both be guesses.
    case unavailable
}

/// Attribute-only Keychain probe result: presence and ACL state without
/// ever requesting the secret payload (SDD §7.2).
public enum MetaKeychainProbe: Equatable, Sendable {
    case present
    case blocked
    case missing
    case failed(OSStatus)
}

public protocol MetaCredentialReading: Sendable {
    func resolve() -> MetaLoginResolution
    /// Login presence for Settings, detectable without reading any secret.
    func hasLogin() -> Bool
    /// Three-way state for Settings (detected / blocked / missing).
    func detection() -> MetaLoginDetection
}

public extension MetaCredentialReading {
    func detection() -> MetaLoginDetection {
        switch resolve() {
        case .token: return .detected
        case .keychainBlocked: return .keychainBlocked
        case .unavailable: return .unavailable
        case .missing: return .missing
        }
    }
}

/// Reads the Muse Code CLI's device-code login, shared read-only.
///
/// Subscription quota answers only this credential: dashboard `LLM_` keys,
/// minted `LLM|` keys and `META_API_KEY` all get 401 from the mint
/// endpoint, so they are never consulted here. Resolution order mirrors
/// the CLI's own: an inline token in `~/.config/muse/auth.json` wins over
/// the Keychain item the CLI writes (`ai.meta.dev.credentials` / `meta`).
///
/// The credential is shared with a CLI, so this reader is strictly
/// read-only: no refresh, no write-back, no interactive prompt (the same
/// structural rule as `AnthropicConfig.manageOAuthRefresh = false`).
public struct MetaCredentialReader: MetaCredentialReading {
    public static let keychainService = "ai.meta.dev.credentials"
    public static let keychainAccount = "meta"
    public static let authPathEnvironmentKey = "MUSE_AUTH_PATH"
    private static let tokenPrefix = "dca:"

    public let authFileURL: URL
    private let keychainRead: @Sendable () -> MetaKeychainRead
    private let keychainProbe: (@Sendable () -> MetaKeychainProbe)?

    /// Test/init seam: explicit auth file and Keychain behavior. When no
    /// probe is given, presence derives from the read result (tests only:
    /// production always injects the attribute-only probe, so Settings
    /// detection never requests the secret).
    public init(authFileURL: URL,
                keychainRead: @escaping @Sendable () -> MetaKeychainRead,
                keychainProbe: (@Sendable () -> MetaKeychainProbe)? = nil) {
        self.authFileURL = authFileURL
        self.keychainRead = keychainRead
        self.keychainProbe = keychainProbe
    }

    /// Production reader: resolves the auth file from config/env/default
    /// and reads the CLI's Keychain item prompt-free.
    public init(configPath: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(
            authFileURL: Self.authFileURL(configPath: configPath,
                                          environment: environment, home: home),
            keychainRead: { Self.readKeychain() },
            keychainProbe: { Self.probeKeychain() })
    }

    public init(config: MetaConfig) {
        self.init(configPath: config.authPath)
    }

    public static func authFileURL(configPath: String?,
                                   environment: [String: String],
                                   home: URL) -> URL {
        for candidate in [configPath, environment[authPathEnvironmentKey]] {
            if let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            }
        }
        return home.appendingPathComponent(".config/muse/auth.json")
    }

    public func resolve() -> MetaLoginResolution {
        if let token = authFileRecord()?.inlineToken {
            return .token(token)
        }
        switch keychainRead() {
        case .found(let data):
            guard let token = Self.token(fromKeychainPayload: data) else {
                return .unavailable("unrecognized Muse keychain payload")
            }
            return .token(token)
        case .blocked:
            return .keychainBlocked
        case .missing:
            return .missing
        case .failed(let status):
            return .unavailable("keychain read failed with OSStatus \(status)")
        }
    }

    public func hasLogin() -> Bool {
        if authFileRecord() != nil { return true }
        if let keychainProbe {
            switch keychainProbe() {
            case .present, .blocked: return true
            case .missing, .failed: return false
            }
        }
        return keychainRead() != .missing
    }

    /// Three-way Settings state from the attribute-only probe: the secret
    /// payload is never requested on this path (SDD §7.2). Only readers
    /// built without a probe (tests) fall back to classifying the read
    /// result, discarding any payload unread.
    public func detection() -> MetaLoginDetection {
        if authFileRecord() != nil { return .detected }
        if let keychainProbe {
            switch keychainProbe() {
            case .present: return .detected
            case .blocked: return .keychainBlocked
            case .missing: return .missing
            case .failed: return .unavailable
            }
        }
        switch keychainRead() {
        case .found: return .detected
        case .blocked: return .keychainBlocked
        case .missing: return .missing
        case .failed: return .unavailable
        }
    }

    // MARK: - auth.json

    private struct AuthFileRecord {
        /// Inline token, only when it is a device-code token. A non-`dca:`
        /// inline value cannot read quota and is ignored, not sent.
        let inlineToken: String?
    }

    private struct AuthFile: Decodable {
        let providers: Providers?
        struct Providers: Decodable {
            let meta: Meta?
            struct Meta: Decodable {
                let accessToken: String?
                let mechanism: String?
                enum CodingKeys: String, CodingKey {
                    case accessToken = "access_token"
                    case mechanism
                }
            }
        }
    }

    private func authFileRecord() -> AuthFileRecord? {
        guard let data = try? Data(contentsOf: authFileURL),
              let file = try? JSONDecoder().decode(AuthFile.self, from: data),
              let meta = file.providers?.meta else { return nil }
        let trimmed = meta.accessToken?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let inline = trimmed.hasPrefix(Self.tokenPrefix) ? trimmed : nil
        let isOAuth = meta.mechanism?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "oauth"
        guard inline != nil || isOAuth else { return nil }
        return AuthFileRecord(inlineToken: inline)
    }

    // MARK: - Keychain payload

    /// The item's payload is a JSON object holding the access token under
    /// `access_token` (the spelling the CLI uses in `auth.json`). Only that
    /// contracted shape is accepted, and the `dca:` prefix is the gate.
    static func token(fromKeychainPayload data: Data) -> String? {
        struct Payload: Decodable {
            let access_token: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let token = payload.access_token?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              token.hasPrefix(tokenPrefix) else {
            return nil
        }
        return token
    }

    // MARK: - Keychain access (prompt-free, read-only)

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
    }

    static func readKeychain() -> MetaKeychainRead {
        KeychainPromptSuppressor.withPromptsSuppressed {
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data else { return .missing }
                return .found(data)
            case errSecItemNotFound:
                return .missing
            default:
                if KeychainCredentialReader.isACLBlockedStatus(status) {
                    return .blocked
                }
                return .failed(status)
            }
        }
    }

    /// Presence by attributes only — never requests the secret. An
    /// ACL-blocked item still proves a login exists.
    /// Attribute-only probe: distinguishes present / ACL-blocked / missing
    /// from the query status alone. The secret payload is never requested
    /// (`kSecReturnData` stays unset), so Settings detection can run with
    /// Meta disabled without touching the credential (SDD §7.2).
    static func probeKeychain() -> MetaKeychainProbe {
        KeychainPromptSuppressor.withPromptsSuppressed {
            var query = baseQuery()
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                return .present
            case errSecItemNotFound:
                return .missing
            default:
                return KeychainCredentialReader.isACLBlockedStatus(status)
                    ? .blocked : .failed(status)
            }
        }
    }
}
