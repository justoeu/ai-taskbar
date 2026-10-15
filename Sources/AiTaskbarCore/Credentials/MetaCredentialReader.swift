import Foundation
import Security
import os

/// Outcome of looking for the Muse CLI login, without ever logging the
/// token itself (`docs/SDD-meta-muse.md` §7).
public enum MetaLoginResolution: Equatable, Sendable {
    /// A device-code (`dca:`) access token read live (auth file or Keychain).
    /// Never logged.
    case token(String)
    /// The app's own sealed copy (`MetaTokenStore`), served because the live
    /// Keychain read was refused. Distinct from `.token` so a rejection of
    /// THIS token reads as "authorize again", while a rejection of a live
    /// token reads as "sign in again" (the login itself is dead).
    case storedToken(String)
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
    /// Meta rejected `token`: forget the app's own copy if `token` is it.
    /// True only when a matching copy existed and is now gone. Conformers
    /// without a store keep the default (false).
    func discardStoredToken(_ token: String) -> Bool
}

public extension MetaCredentialReading {
    func detection() -> MetaLoginDetection {
        switch resolve() {
        case .token, .storedToken: return .detected
        case .keychainBlocked: return .keychainBlocked
        case .unavailable: return .unavailable
        case .missing: return .missing
        }
    }

    func authorizePersistently() throws -> Bool { false }

    func discardStoredToken(_ token: String) -> Bool { false }
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
    /// The app's own sealed copy of the token (`MetaTokenStore`), or nil.
    private let tokenStore: MetaTokenStore?

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
                tokenStore: MetaTokenStore? = nil) {
        self.authFileURL = authFileURL
        self.keychainRead = keychainRead
        self.keychainProbe = keychainProbe
        self.authorizer = authorizer
        self.tokenStore = tokenStore
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
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                tokenStore: MetaTokenStore? = Self.defaultTokenStore()) {
        self.init(
            authFileURL: Self.authFileURL(configPath: configPath,
                                          environment: environment, home: home),
            keychainRead: { Self.readKeychain() },
            keychainProbe: { Self.probeKeychain() },
            tokenStore: tokenStore)
    }

    /// The production store; nil (no copy kept) only if Application
    /// Support cannot be prepared — logged, the Keychain path still works.
    public static func defaultTokenStore() -> MetaTokenStore? {
        do {
            return try MetaTokenStore.default()
        } catch {
            AppLog.keychain.error("Muse token store unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
            // The auth file wins; a Keychain-era copy would only go stale.
            tokenStore?.clear()
            return .token(token)
        }
        switch keychainRead() {
        case .found(let data):
            guard let token = Self.token(fromKeychainPayload: data) else {
                return .unavailable("unrecognized Muse keychain payload")
            }
            // Keep the app's own copy: the next Muse self-update drops this
            // grant, and the copy is what keeps that from costing the user
            // a password (see `MetaTokenStore`).
            if let tokenStore {
                do {
                    try tokenStore.save(token)
                } catch {
                    AppLog.keychain.error("Muse token copy not saved: \(error.localizedDescription, privacy: .public)")
                }
            }
            return .token(token)
        case .blocked:
            // No `/usr/bin/security` fallback here (unlike the Claude
            // item): the Muse CLI writes this item natively, and its
            // rewrites drop every grant — the tool then raised a password
            // dialog of its own (a separate process, outside
            // `KeychainPromptSuppressor`). The stored copy answers instead;
            // only without one does the Authorize banner appear.
            if let stored = tokenStore?.load() { return .storedToken(stored) }
            return .keychainBlocked
        case .missing:
            // `muse logout`: the login is gone, so is the copy.
            tokenStore?.clear()
            return .missing
        case .failed(let status):
            if let stored = tokenStore?.load() { return .storedToken(stored) }
            return .unavailable("keychain read failed with OSStatus \(status)")
        }
    }

    public func discardStoredToken(_ token: String) -> Bool {
        guard let tokenStore, tokenStore.load() == token else { return false }
        return tokenStore.clear()
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
        // An inline token is self-sufficient. An oauth marker alone only
        // says the token should be in the Keychain, so fall through to
        // the probe: marker present + item deleted/blocked must not read
        // as "Detected".
        if authFileRecord()?.inlineToken != nil { return .detected }
        if let keychainProbe {
            switch keychainProbe() {
            case .present: return .detected
            // Mirrors `resolve()`: wherever it would serve the stored copy,
            // the login counts as detected.
            case .blocked: return tokenStore?.load() != nil ? .detected : .keychainBlocked
            case .missing: return .missing
            case .failed: return tokenStore?.load() != nil ? .detected : .unavailable
            }
        }
        switch keychainRead() {
        case .found: return .detected
        case .blocked: return tokenStore?.load() != nil ? .detected : .keychainBlocked
        case .missing: return .missing
        case .failed: return tokenStore?.load() != nil ? .detected : .unavailable
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
        // Bounded read: the path is steerable (config/env), so never slurp
        // an unbounded or non-regular file on the scheduled path. A file
        // that exists but does not parse is logged, then treated as absent
        // so the Keychain path still gets its chance.
        guard let data = Self.boundedRead(authFileURL) else { return nil }
        let file: AuthFile
        do {
            file = try SharedCoders.decoder.decode(AuthFile.self, from: data)
        } catch {
            AppLog.keychain.error("Muse auth file present but unparseable; falling back to Keychain.")
            return nil
        }
        guard let meta = file.providers?.meta else { return nil }
        let trimmed = meta.accessToken?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let inline = trimmed.hasPrefix(Self.tokenPrefix) ? trimmed : nil
        let isOAuth = meta.mechanism?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "oauth"
        guard inline != nil || isOAuth else { return nil }
        return AuthFileRecord(inlineToken: inline)
    }

    /// At most 64 KiB from a regular file; nil for missing/oversized/other.
    static func boundedRead(_ url: URL, limit: Int = 65_536) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else {
            return nil
        }
        return data
    }

    // MARK: - Keychain payload

    /// The item's payload is a JSON object holding the access token under
    /// `access_token` (the spelling the CLI uses in `auth.json`). Only that
    /// contracted shape is accepted, and the `dca:` prefix is the gate.
    static func token(fromKeychainPayload data: Data) -> String? {
        struct Payload: Decodable {
            let access_token: String?
        }
        guard let payload = try? SharedCoders.decoder.decode(Payload.self, from: data),
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
