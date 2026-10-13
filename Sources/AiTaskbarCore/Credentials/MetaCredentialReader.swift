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
    /// User-initiated durable Keychain authorization (Authorize button
    /// only, never scheduled). False means the user canceled.
    func authorizePersistently() throws -> Bool
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

    func authorizePersistently() throws -> Bool { false }
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
    private let authorizer: @Sendable () throws -> Bool
    /// `/usr/bin/security` fallback payload for the same item, or nil.
    private let securityToolRead: @Sendable () -> Data?

    /// Test/init seam: explicit auth file and Keychain behavior. When no
    /// probe is given, presence derives from the read result (tests only:
    /// production always injects the attribute-only probe, so Settings
    /// detection never requests the secret).
    public init(authFileURL: URL,
                keychainRead: @escaping @Sendable () -> MetaKeychainRead,
                keychainProbe: (@Sendable () -> MetaKeychainProbe)? = nil,
                authorizer: @escaping @Sendable () throws -> Bool = {
                    try KeychainAccessAuthorizer.authorize(
                        service: MetaCredentialReader.keychainService,
                        account: MetaCredentialReader.keychainAccount) == .authorized
                },
                securityToolRead: @escaping @Sendable () -> Data? = { nil }) {
        self.authFileURL = authFileURL
        self.keychainRead = keychainRead
        self.keychainProbe = keychainProbe
        self.authorizer = authorizer
        self.securityToolRead = securityToolRead
    }

    /// The one intentional interactive prompt, behind the Authorize
    /// button only: securityd extends the item ACL to this signing
    /// identity, then a silent read of the same item must succeed
    /// (`KeychainAccessAuthorizer` contract). Data read is discarded.
    public func authorizePersistently() throws -> Bool {
        try authorizer()
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
            keychainProbe: { Self.probeKeychain() },
            securityToolRead: { Self.readViaSecurityTool() })
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
            // Same item through /usr/bin/security (the Claude-proven
            // fallback): the tool is trusted by the item even when this
            // binary is not, so no password prompt is ever needed. Only
            // when the tool also fails does the Authorize banner remain.
            if let data = securityToolRead(),
               let token = Self.token(fromKeychainPayload: data) {
                return .token(token)
            }
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
    private static let securityTool = SecurityToolCredentialReader()
    private static let didLogFallback = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Same item, read by `/usr/bin/security` instead of this binary —
    /// the fallback that ended the per-build password prompts for the
    /// Claude item, applied under its exact guardrails: skipped when the
    /// item's keychain is locked (the same fast-fail would mean "locked"
    /// and the tool would raise the unlock dialog), exact-match
    /// arguments pinned to the item's own keychain file, payload never
    /// logged, cooldowns owned by `SecurityToolCredentialReader`.
    /// Blocking: call only via `resolve()` from an off-pool thread.
    static func readViaSecurityTool() -> Data? {
        guard let keychain = itemKeychain(), KeychainCredentialReader.isUnlocked(keychain) else {
            AppLog.keychain.notice("Muse keychain read blocked and the item's keychain is locked or unresolved; not consulting /usr/bin/security.")
            return nil
        }
        do {
            let data = try securityTool.read(
                service: keychainService, account: keychainAccount,
                keychainPaths: [KeychainCredentialReader.path(of: keychain)].compactMap { $0 })
            let first = didLogFallback.withLock { logged -> Bool in
                defer { logged = true }
                return !logged
            }
            if first {
                AppLog.keychain.notice("Direct Muse keychain read ACL-blocked; credential read through /usr/bin/security (no prompt). Authorize remains available for direct reads.")
            }
            return data
        } catch SecurityToolCredentialReader.Failure.coolingDown {
            return nil
        } catch {
            AppLog.keychain.error("Muse security tool fallback unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The keychain file holding the login item (reference query, no decrypt).
    private static func itemKeychain() -> SecKeychain? {
        KeychainPromptSuppressor.withPromptsSuppressed {
            var query = baseQuery()
            query[kSecReturnRef as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let item else { return nil }
            var keychain: SecKeychain?
            guard SecKeychainItemCopyKeychain(item as! SecKeychainItem, &keychain) == errSecSuccess else {
                return nil
            }
            return keychain
        }
    }

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
