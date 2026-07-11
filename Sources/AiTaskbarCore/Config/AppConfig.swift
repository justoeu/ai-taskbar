import Foundation

public struct AppConfig: Codable, Sendable, Equatable {
    public var ui: UIConfig
    public var thresholds: ThresholdsConfig
    public var notifications: NotificationsConfig
    public var security: SecurityConfig
    public var updates: UpdatesConfig
    public var anthropic: AnthropicConfig
    public var openai: OpenAIConfig
    public var zai: ZAIConfig
    public var openrouter: OpenRouterConfig
    public var kimi: KimiConfig
    public var gemini: GeminiConfig
    public var deepseek: DeepSeekConfig
    public var xai: XAIConfig

    public init(ui: UIConfig = .init(),
                thresholds: ThresholdsConfig = .init(),
                notifications: NotificationsConfig = .init(),
                security: SecurityConfig = .init(),
                updates: UpdatesConfig = .init(),
                anthropic: AnthropicConfig = .init(),
                openai: OpenAIConfig = .init(),
                zai: ZAIConfig = .init(),
                openrouter: OpenRouterConfig = .init(),
                kimi: KimiConfig = .init(),
                gemini: GeminiConfig = .init(),
                deepseek: DeepSeekConfig = .init(),
                xai: XAIConfig = .init()) {
        self.ui = ui
        self.thresholds = thresholds
        self.notifications = notifications
        self.security = security
        self.updates = updates
        self.anthropic = anthropic
        self.openai = openai
        self.zai = zai
        self.openrouter = openrouter
        self.kimi = kimi
        self.gemini = gemini
        self.deepseek = deepseek
        self.xai = xai
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ui             = try c.decodeIfPresent(UIConfig.self, forKey: .ui) ?? .init()
        thresholds     = try c.decodeIfPresent(ThresholdsConfig.self, forKey: .thresholds) ?? .init()
        notifications  = try c.decodeIfPresent(NotificationsConfig.self, forKey: .notifications) ?? .init()
        security       = try c.decodeIfPresent(SecurityConfig.self, forKey: .security) ?? .init()
        updates        = try c.decodeIfPresent(UpdatesConfig.self, forKey: .updates) ?? .init()
        anthropic      = try c.decodeIfPresent(AnthropicConfig.self, forKey: .anthropic) ?? .init()
        openai         = try c.decodeIfPresent(OpenAIConfig.self, forKey: .openai) ?? .init()
        zai            = try c.decodeIfPresent(ZAIConfig.self, forKey: .zai) ?? .init()
        openrouter     = try c.decodeIfPresent(OpenRouterConfig.self, forKey: .openrouter) ?? .init()
        kimi           = try c.decodeIfPresent(KimiConfig.self, forKey: .kimi) ?? .init()
        gemini         = try c.decodeIfPresent(GeminiConfig.self, forKey: .gemini) ?? .init()
        deepseek       = try c.decodeIfPresent(DeepSeekConfig.self, forKey: .deepseek) ?? .init()
        xai            = try c.decodeIfPresent(XAIConfig.self, forKey: .xai) ?? .init()
    }
}

public struct UpdatesConfig: Codable, Sendable, Equatable {
    /// Master switch — set false to disable the "Check for updates" UI
    /// entirely. Default true.
    public var enabled: Bool = true

    /// GitHub `owner/repo` to query for releases. Default points at the
    /// canonical upstream — forks should override this in `config.toml`
    /// (`[updates] owner_repo = "yourname/ai-taskbar"`).
    public var ownerRepo: String = "justoeu/ai-taskbar"

    /// When true, prerelease tags (`v0.2.0-beta1`) are also considered.
    /// Defaults to false → only stable releases trigger update offers.
    public var includePrereleases: Bool = false

    public init(enabled: Bool = true,
                ownerRepo: String = "justoeu/ai-taskbar",
                includePrereleases: Bool = false) {
        self.enabled = enabled
        self.ownerRepo = ownerRepo
        self.includePrereleases = includePrereleases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        ownerRepo = try c.decodeIfPresent(String.self, forKey: .ownerRepo) ?? "justoeu/ai-taskbar"
        includePrereleases = try c.decodeIfPresent(Bool.self, forKey: .includePrereleases) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case ownerRepo = "owner_repo"
        case includePrereleases = "include_prereleases"
    }
}

public struct SecurityConfig: Codable, Sendable, Equatable {
    /// Hosts that should be TLS-pinned. Pinning uses SPKI hash with
    /// Trust-On-First-Use: the first successful handshake stores the hash,
    /// every subsequent connection verifies against it. Cert rotations on
    /// the same SPKI keep working; MitM with a different cert is rejected.
    /// Empty list (default) = no pinning.
    public var pinHosts: [String] = []

    /// When true, a pin mismatch is logged but the connection still proceeds.
    /// Useful for first deployment / debugging. Default false (strict).
    public var pinAuditOnly: Bool = false

    public init(pinHosts: [String] = [], pinAuditOnly: Bool = false) {
        self.pinHosts = pinHosts
        self.pinAuditOnly = pinAuditOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinHosts = try c.decodeIfPresent([String].self, forKey: .pinHosts) ?? []
        pinAuditOnly = try c.decodeIfPresent(Bool.self, forKey: .pinAuditOnly) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case pinHosts = "pin_hosts"
        case pinAuditOnly = "pin_audit_only"
    }
}

public struct ThresholdsConfig: Codable, Sendable, Equatable {
    public var warning: Double = 70
    public var critical: Double = 90

    public init(warning: Double = 70, critical: Double = 90) {
        self.warning = warning
        self.critical = critical
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        warning  = c.flexibleDouble(forKey: .warning,  default: 70)
        critical = c.flexibleDouble(forKey: .critical, default: 90)
    }

    enum CodingKeys: String, CodingKey { case warning, critical }
}

public struct NotificationsConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var notifyAt: [Double] = [90, 100]
    /// When true, notifications avoid revealing which LLM you use in the
    /// title — useful if you keep lock-screen previews on. The vendor name
    /// moves to the body (hidden by macOS' "Show previews when unlocked"
    /// setting). Default false to preserve familiar behavior.
    public var discreet: Bool = false

    public init(enabled: Bool = true,
                notifyAt: [Double] = [90, 100],
                discreet: Bool = false) {
        self.enabled = enabled
        self.notifyAt = notifyAt
        self.discreet = discreet
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled  = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        notifyAt = c.flexibleDoubleArray(forKey: .notifyAt, default: [90, 100])
        discreet = try c.decodeIfPresent(Bool.self, forKey: .discreet) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case notifyAt = "notify_at"
        case discreet
    }
}

/// Tolerant decoders that bridge TOML's int-only literals to Swift Doubles.
/// TOML treats `70` (no dot) as Int64 and refuses to auto-convert to Double.
extension KeyedDecodingContainer {
    public func flexibleDouble(forKey key: Key, default defaultValue: Double) -> Double {
        flexibleDoubleIfPresent(forKey: key) ?? defaultValue
    }

    /// Tolerant `Double?` decoder for keys that may be present as int (TOML
    /// `70`), float (JSON `70.0`), or absent. Used everywhere a vendor API
    /// has been seen to flip between int/float for the same field. Replaces
    /// the `(try? decodeIfPresent Double) ?? (try? decodeIfPresent Int64)
    /// .map(Double.init) ?? nil` boilerplate that used to live in every wire
    /// type.
    public func flexibleDoubleIfPresent(forKey key: Key) -> Double? {
        if let outer: Double? = try? decodeIfPresent(Double.self, forKey: key),
           let d = outer { return d }
        if let outer: Int64? = try? decodeIfPresent(Int64.self, forKey: key),
           let i = outer { return Double(i) }
        return nil
    }

    public func flexibleDoubleArray(forKey key: Key, default defaultValue: [Double]) -> [Double] {
        if let outer: [Double]? = try? decodeIfPresent([Double].self, forKey: key),
           let arr = outer { return arr }
        if let outer: [Int64]? = try? decodeIfPresent([Int64].self, forKey: key),
           let arr = outer { return arr.map(Double.init) }
        return defaultValue
    }
}

public struct UIConfig: Codable, Sendable, Equatable {
    public var primary: VendorId?
    public var menuBarMode: MenuBarMode = .iconAndPercent
    /// Auto-refresh cadence in seconds. Minimum 15 s is enforced at runtime
    /// to avoid spamming undocumented vendor endpoints. Default 300 s (5 min)
    /// keeps every vendor comfortably below their 429 thresholds.
    public var refreshIntervalSeconds: Double = 300
    /// Force a specific UI language code (e.g. "pt-BR", "en", "es"). When
    /// nil, the macOS system language is used. Useful when you want this
    /// app in a different language than the rest of macOS.
    public var language: String?

    public init(primary: VendorId? = nil,
                menuBarMode: MenuBarMode = .iconAndPercent,
                refreshIntervalSeconds: Double = 300,
                language: String? = nil) {
        self.primary = primary
        self.menuBarMode = menuBarMode
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.language = language
    }

    enum CodingKeys: String, CodingKey {
        case primary
        case menuBarMode = "menu_bar_mode"
        case refreshIntervalSeconds = "refresh_interval_seconds"
        case language
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try c.decodeIfPresent(String.self, forKey: .primary) {
            self.primary = VendorId(rawValue: s)
        } else {
            self.primary = nil
        }
        if let s = try c.decodeIfPresent(String.self, forKey: .menuBarMode),
           let m = MenuBarMode(rawValue: s) {
            self.menuBarMode = m
        } else {
            self.menuBarMode = .iconAndPercent
        }
        self.refreshIntervalSeconds = max(15, c.flexibleDouble(forKey: .refreshIntervalSeconds, default: 300))
        self.language = try c.decodeIfPresent(String.self, forKey: .language)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(primary?.rawValue, forKey: .primary)
        try c.encode(menuBarMode.rawValue, forKey: .menuBarMode)
        try c.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try c.encodeIfPresent(language, forKey: .language)
    }
}

public enum MenuBarMode: String, Codable, Sendable, CaseIterable {
    case icon                  = "icon"
    case iconAndPercent        = "icon_and_percent"
    case rotating              = "rotating"
}

public struct AnthropicConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var keychainService: String?
    /// Account name (`kSecAttrAccount`) to pin to when the user has multiple
    /// Claude Keychain entries (e.g. work + personal). When nil and multiple
    /// entries exist, the reader picks lexicographically and logs a warning.
    public var keychainAccount: String?
    /// When `true`, the provider performs the OAuth `refresh_token` exchange
    /// itself and writes the rotated tokens back to the shared
    /// `Claude Code-credentials` Keychain item once the access token nears
    /// expiry. **Default `false`** — a usage *monitor* should not mutate the
    /// credential it shares with the Claude Code CLI. Anthropic rotates the
    /// refresh token on every exchange, so refreshing here invalidates the
    /// copy other already-running CLI sessions hold (→ "please re-login"),
    /// and the write-back itself trips a Keychain ACL prompt on ad-hoc
    /// builds. Read-only mode reads whatever token the CLI maintains and lets
    /// the CLI own renewal; if the token is briefly expired the request 401s
    /// and the last cached snapshot is served until the CLI refreshes (on a
    /// cold cache with no prior snapshot the fetch surfaces the error instead).
    /// Opt in only if you run the app standalone without the CLI.
    public var manageOAuthRefresh: Bool = false

    public init(enabled: Bool = true,
                keychainService: String? = nil,
                keychainAccount: String? = nil,
                manageOAuthRefresh: Bool = false) {
        self.enabled = enabled
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.manageOAuthRefresh = manageOAuthRefresh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        keychainService = try c.decodeIfPresent(String.self, forKey: .keychainService)
        keychainAccount = try c.decodeIfPresent(String.self, forKey: .keychainAccount)
        manageOAuthRefresh = try c.decodeIfPresent(Bool.self, forKey: .manageOAuthRefresh) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case keychainService = "keychain_service"
        case keychainAccount = "keychain_account"
        case manageOAuthRefresh = "manage_oauth_refresh"
    }
}

public struct OpenAIConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var codexAuthPath: String?
    /// When `true`, the provider performs the OAuth `refresh_token` exchange
    /// itself and writes the rotated tokens back to `~/.codex/auth.json`
    /// once the id-token nears expiry. **Default `false`** — the file is
    /// shared with the Codex CLI, and rotating the refresh token here would
    /// invalidate the copy other running CLI sessions hold (→ forced
    /// re-login). Read-only mode reads whatever token the Codex CLI maintains
    /// and lets the CLI own renewal; if the token is briefly expired the
    /// request 401s and the last cached snapshot is served until the CLI
    /// refreshes (on a cold cache the fetch surfaces the error instead). Opt
    /// in only if you run the app standalone without the Codex CLI.
    public var manageOAuthRefresh: Bool = false

    public init(enabled: Bool = true,
                codexAuthPath: String? = nil,
                manageOAuthRefresh: Bool = false) {
        self.enabled = enabled
        self.codexAuthPath = codexAuthPath
        self.manageOAuthRefresh = manageOAuthRefresh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        codexAuthPath = try c.decodeIfPresent(String.self, forKey: .codexAuthPath)
        manageOAuthRefresh = try c.decodeIfPresent(Bool.self, forKey: .manageOAuthRefresh) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case codexAuthPath = "codex_auth_path"
        case manageOAuthRefresh = "manage_oauth_refresh"
    }
}

public struct ZAIConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var apiKeyEnv: String = "ZAI_API_KEY"
    public var apiKey: String?
    public var planTier: String?

    public init(enabled: Bool = true,
                apiKeyEnv: String = "ZAI_API_KEY",
                apiKey: String? = nil,
                planTier: String? = nil) {
        self.enabled = enabled
        self.apiKeyEnv = apiKeyEnv
        self.apiKey = apiKey
        self.planTier = planTier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv) ?? "ZAI_API_KEY"
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        planTier = try c.decodeIfPresent(String.self, forKey: .planTier)
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case apiKeyEnv = "api_key_env"
        case apiKey = "api_key"
        case planTier = "plan_tier"
    }
}

public struct KimiConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var apiKeyEnv: String = "MOONSHOT_API_KEY"
    public var apiKey: String?
    /// Base URL — `https://api.moonshot.ai/v1` (international) or
    /// `https://api.moonshot.cn/v1` (China region). Validated to prevent
    /// API-key exfil via attacker-controlled config: only `https://` and the
    /// two official Moonshot hosts are accepted; anything else falls back to
    /// the default.
    public var baseURL: String = "https://api.moonshot.ai/v1"

    /// Hosts allowed in `base_url`. Centralized so tests and security review
    /// can reference the same list. Sub-domains are NOT auto-allowed.
    public static let allowedHosts: Set<String> = [
        "api.moonshot.ai",
        "api.moonshot.cn",
    ]
    public static let defaultBaseURL = "https://api.moonshot.ai/v1"

    public init(enabled: Bool = true,
                apiKeyEnv: String = "MOONSHOT_API_KEY",
                apiKey: String? = nil,
                baseURL: String = defaultBaseURL) {
        self.enabled = enabled
        self.apiKeyEnv = apiKeyEnv
        self.apiKey = apiKey
        self.baseURL = Self.validate(baseURL) ?? Self.defaultBaseURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv) ?? "MOONSHOT_API_KEY"
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        let raw = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.defaultBaseURL
        if let validated = Self.validate(raw) {
            baseURL = validated
        } else {
            // `raw` is user input — public so the user sees what they typed.
            AppLog.config.warning("KimiConfig.base_url \(raw, privacy: .public) rejected (must be https:// to an allowed Moonshot host) — falling back to default")
            baseURL = Self.defaultBaseURL
        }
    }

    /// Returns `raw` if it is an `https://` URL pointing to an allowed host;
    /// otherwise nil. Lowercases scheme/host before comparing.
    public static func validate(_ raw: String) -> String? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host)
        else { return nil }
        return raw
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case apiKeyEnv = "api_key_env"
        case apiKey = "api_key"
        case baseURL = "base_url"
    }
}

public struct OpenRouterConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var apiKeyEnv: String = "OPENROUTER_API_KEY"
    public var apiKey: String?

    public init(enabled: Bool = true,
                apiKeyEnv: String = "OPENROUTER_API_KEY",
                apiKey: String? = nil) {
        self.enabled = enabled
        self.apiKeyEnv = apiKeyEnv
        self.apiKey = apiKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv) ?? "OPENROUTER_API_KEY"
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case apiKeyEnv = "api_key_env"
        case apiKey = "api_key"
    }
}

public struct GeminiConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var apiKeyEnv: String = "GEMINI_API_KEY"
    public var apiKey: String?
    /// Base URL — defaults to the Generative Language API host. Validated to
    /// prevent API-key exfil via attacker-controlled config: only `https://`
    /// and the official Google AI hosts are accepted; anything else falls
    /// back to the default.
    public var baseURL: String = "https://generativelanguage.googleapis.com/v1beta"

    /// Hosts allowed in `base_url`. Centralized so tests and security review
    /// can reference the same list. Sub-domains are NOT auto-allowed.
    public static let allowedHosts: Set<String> = [
        "generativelanguage.googleapis.com",
    ]
    public static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta"

    public init(enabled: Bool = true,
                apiKeyEnv: String = "GEMINI_API_KEY",
                apiKey: String? = nil,
                baseURL: String = defaultBaseURL) {
        self.enabled = enabled
        self.apiKeyEnv = apiKeyEnv
        self.apiKey = apiKey
        self.baseURL = Self.validate(baseURL) ?? Self.defaultBaseURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv) ?? "GEMINI_API_KEY"
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        let raw = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.defaultBaseURL
        if let validated = Self.validate(raw) {
            baseURL = validated
        } else {
            AppLog.config.warning("GeminiConfig.base_url \(raw, privacy: .public) rejected (must be https:// to an allowed Google AI host) — falling back to default")
            baseURL = Self.defaultBaseURL
        }
    }

    /// Returns `raw` if it is an `https://` URL pointing to an allowed Google
    /// AI host AND whose path is exactly one of the known API-version
    /// namespaces (or a subpath rooted on one). Otherwise nil.
    ///
    /// We're strict here on purpose: a previous `hasPrefix("/v1")` check
    /// would accept `/v1banana`, `/v1xxxxxx`, etc. — typos pass validation
    /// then produce 404s at runtime that the user has to debug. Anchoring
    /// on a closed set of accepted prefixes turns the typo into a
    /// startup-time NSLog warning instead.
    public static let allowedAPIVersions: [String] = ["/v1", "/v1beta", "/v1alpha"]

    public static func validate(_ raw: String) -> String? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host)
        else { return nil }
        let path = url.path
        let pathOK = allowedAPIVersions.contains { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
        guard pathOK else { return nil }
        return raw
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case apiKeyEnv = "api_key_env"
        case apiKey = "api_key"
        case baseURL = "base_url"
    }
}

public struct DeepSeekConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var apiKeyEnv: String = "DEEPSEEK_API_KEY"
    public var apiKey: String?
    /// Base URL — `https://api.deepseek.com`. Validated to prevent API-key
    /// exfil via attacker-controlled config: only `https://` and the official
    /// DeepSeek host are accepted; anything else falls back to the default.
    public var baseURL: String = "https://api.deepseek.com"

    /// Hosts allowed in `base_url`. Centralized so tests and security review
    /// can reference the same list. Sub-domains are NOT auto-allowed.
    public static let allowedHosts: Set<String> = [
        "api.deepseek.com",
    ]
    public static let defaultBaseURL = "https://api.deepseek.com"

    public init(enabled: Bool = true,
                apiKeyEnv: String = "DEEPSEEK_API_KEY",
                apiKey: String? = nil,
                baseURL: String = defaultBaseURL) {
        self.enabled = enabled
        self.apiKeyEnv = apiKeyEnv
        self.apiKey = apiKey
        self.baseURL = Self.validate(baseURL) ?? Self.defaultBaseURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv) ?? "DEEPSEEK_API_KEY"
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        let raw = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.defaultBaseURL
        if let validated = Self.validate(raw) {
            baseURL = validated
        } else {
            AppLog.config.warning("DeepSeekConfig.base_url \(raw, privacy: .public) rejected (must be https:// to an allowed DeepSeek host) — falling back to default")
            baseURL = Self.defaultBaseURL
        }
    }

    /// Returns `raw` if it is an `https://` URL pointing to an allowed host;
    /// otherwise nil. Lowercases scheme/host before comparing.
    public static func validate(_ raw: String) -> String? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host)
        else { return nil }
        return raw
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case apiKeyEnv = "api_key_env"
        case apiKey = "api_key"
        case baseURL = "base_url"
    }
}

/// xAI Management API config. Inference keys (`xai-...` on `api.x.ai`) cannot
/// read billing; a separate **management key** from console.x.ai → Settings →
/// Management Keys is required, plus the team UUID.
public struct XAIConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var apiKeyEnv: String = "XAI_MANAGEMENT_KEY"
    public var apiKey: String?
    /// Team UUID from https://console.x.ai/team/default/settings/team
    public var teamId: String = ""
    /// Management API base — `https://management-api.x.ai`. Host-allowlisted.
    public var baseURL: String = "https://management-api.x.ai"

    public static let allowedHosts: Set<String> = [
        "management-api.x.ai",
    ]
    public static let defaultBaseURL = "https://management-api.x.ai"

    public init(enabled: Bool = true,
                apiKeyEnv: String = "XAI_MANAGEMENT_KEY",
                apiKey: String? = nil,
                teamId: String = "",
                baseURL: String = defaultBaseURL) {
        self.enabled = enabled
        self.apiKeyEnv = apiKeyEnv
        self.apiKey = apiKey
        self.teamId = teamId
        self.baseURL = Self.validate(baseURL) ?? Self.defaultBaseURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv) ?? "XAI_MANAGEMENT_KEY"
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        teamId = try c.decodeIfPresent(String.self, forKey: .teamId) ?? ""
        let raw = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.defaultBaseURL
        if let validated = Self.validate(raw) {
            baseURL = validated
        } else {
            AppLog.config.warning("XAIConfig.base_url \(raw, privacy: .public) rejected (must be https:// to an allowed xAI management host) — falling back to default")
            baseURL = Self.defaultBaseURL
        }
    }

    public static func validate(_ raw: String) -> String? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host)
        else { return nil }
        return raw
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case apiKeyEnv = "api_key_env"
        case apiKey = "api_key"
        case teamId = "team_id"
        case baseURL = "base_url"
    }
}

extension AppConfig {
    enum CodingKeys: String, CodingKey {
        case ui, thresholds, notifications, security, updates,
             anthropic, openai, zai, openrouter, kimi, gemini, deepseek, xai
    }
}
