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
                gemini: GeminiConfig = .init()) {
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

    public init(enabled: Bool = true,
                keychainService: String? = nil,
                keychainAccount: String? = nil) {
        self.enabled = enabled
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        keychainService = try c.decodeIfPresent(String.self, forKey: .keychainService)
        keychainAccount = try c.decodeIfPresent(String.self, forKey: .keychainAccount)
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case keychainService = "keychain_service"
        case keychainAccount = "keychain_account"
    }
}

public struct OpenAIConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = true
    public var codexAuthPath: String?

    public init(enabled: Bool = true, codexAuthPath: String? = nil) {
        self.enabled = enabled
        self.codexAuthPath = codexAuthPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        codexAuthPath = try c.decodeIfPresent(String.self, forKey: .codexAuthPath)
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case codexAuthPath = "codex_auth_path"
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
            NSLog("ai-taskbar: KimiConfig.base_url %@ rejected (must be https:// to an allowed Moonshot host) — falling back to default", raw)
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
            NSLog("ai-taskbar: GeminiConfig.base_url %@ rejected (must be https:// to an allowed Google AI host) — falling back to default", raw)
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

extension AppConfig {
    enum CodingKeys: String, CodingKey {
        case ui, thresholds, notifications, security, updates,
             anthropic, openai, zai, openrouter, kimi, gemini
    }
}
