import Foundation
import Testing
@testable import AiTaskbarApp
import AiTaskbarCore

/// Pins `SettingsViewModel.diff` field by field (CPX-DED-005). Each row flips
/// exactly one stored property of `AppConfig` and names the single
/// `ConfigChange` the diff must emit for it. The exhaustiveness guard then
/// compares the rows against `Mirror` of every section, so adding a field to
/// a config struct fails here until the field is both diffed and listed.
@MainActor
@Suite("SettingsViewModel.diff")
struct SettingsViewModelDiffTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let section: String
        let field: String
        let mutate: @Sendable (inout AppConfig) -> Void
        let expected: ConfigChange
        /// Set only when one field change deliberately emits more than one
        /// change (saving a TypeSafe key also enables the provider).
        var expectedAll: [ConfigChange]? = nil
        var testDescription: String { "\(section).\(field)" }
    }

    nonisolated static let rows: [Row] = [
        // [ui]
        Row(section: "ui", field: "primary", mutate: { $0.ui.primary = .openai },
            expected: .string(section: "ui", key: "primary", value: VendorId.openai.rawValue)),
        Row(section: "ui", field: "menuBarMode", mutate: { $0.ui.menuBarMode = .icon },
            expected: .string(section: "ui", key: "menu_bar_mode", value: MenuBarMode.icon.rawValue)),
        Row(section: "ui", field: "refreshIntervalSeconds", mutate: { $0.ui.refreshIntervalSeconds = 120 },
            expected: .double(section: "ui", key: "refresh_interval_seconds", value: 120)),
        Row(section: "ui", field: "language", mutate: { $0.ui.language = "pt-BR" },
            expected: .string(section: "ui", key: "language", value: "pt-BR")),
        // [thresholds]
        Row(section: "thresholds", field: "warning", mutate: { $0.thresholds.warning = 60 },
            expected: .double(section: "thresholds", key: "warning", value: 60)),
        Row(section: "thresholds", field: "critical", mutate: { $0.thresholds.critical = 80 },
            expected: .double(section: "thresholds", key: "critical", value: 80)),
        // [notifications]
        Row(section: "notifications", field: "enabled", mutate: { $0.notifications.enabled = false },
            expected: .bool(section: "notifications", key: "enabled", value: false)),
        Row(section: "notifications", field: "notifyAt", mutate: { $0.notifications.notifyAt = [80, 95] },
            expected: .doubleArray(section: "notifications", key: "notify_at", value: [80, 95])),
        Row(section: "notifications", field: "discreet", mutate: { $0.notifications.discreet = true },
            expected: .bool(section: "notifications", key: "discreet", value: true)),
        // [security]
        Row(section: "security", field: "pinHosts", mutate: { $0.security.pinHosts = ["api.anthropic.com"] },
            expected: .stringArray(section: "security", key: "pin_hosts", value: ["api.anthropic.com"])),
        Row(section: "security", field: "pinAuditOnly", mutate: { $0.security.pinAuditOnly = true },
            expected: .bool(section: "security", key: "pin_audit_only", value: true)),
        // [updates]
        Row(section: "updates", field: "enabled", mutate: { $0.updates.enabled = false },
            expected: .bool(section: "updates", key: "enabled", value: false)),
        Row(section: "updates", field: "ownerRepo", mutate: { $0.updates.ownerRepo = "someone/fork" },
            expected: .string(section: "updates", key: "owner_repo", value: "someone/fork")),
        Row(section: "updates", field: "includePrereleases", mutate: { $0.updates.includePrereleases = true },
            expected: .bool(section: "updates", key: "include_prereleases", value: true)),
        // [anthropic]
        Row(section: "anthropic", field: "enabled", mutate: { $0.anthropic.enabled = false },
            expected: .bool(section: "anthropic", key: "enabled", value: false)),
        Row(section: "anthropic", field: "keychainService", mutate: { $0.anthropic.keychainService = "svc" },
            expected: .string(section: "anthropic", key: "keychain_service", value: "svc")),
        Row(section: "anthropic", field: "keychainAccount", mutate: { $0.anthropic.keychainAccount = "acct" },
            expected: .string(section: "anthropic", key: "keychain_account", value: "acct")),
        Row(section: "anthropic", field: "manageOAuthRefresh", mutate: { $0.anthropic.manageOAuthRefresh = true },
            expected: .bool(section: "anthropic", key: "manage_oauth_refresh", value: true)),
        // [openai]
        Row(section: "openai", field: "enabled", mutate: { $0.openai.enabled = false },
            expected: .bool(section: "openai", key: "enabled", value: false)),
        Row(section: "openai", field: "codexAuthPath", mutate: { $0.openai.codexAuthPath = "/tmp/auth.json" },
            expected: .string(section: "openai", key: "codex_auth_path", value: "/tmp/auth.json")),
        Row(section: "openai", field: "manageOAuthRefresh", mutate: { $0.openai.manageOAuthRefresh = true },
            expected: .bool(section: "openai", key: "manage_oauth_refresh", value: true)),
        // [zai]
        Row(section: "zai", field: "enabled", mutate: { $0.zai.enabled = false },
            expected: .bool(section: "zai", key: "enabled", value: false)),
        Row(section: "zai", field: "apiKeyEnv", mutate: { $0.zai.apiKeyEnv = "ENV_Z" },
            expected: .string(section: "zai", key: "api_key_env", value: "ENV_Z")),
        Row(section: "zai", field: "apiKey", mutate: { $0.zai.apiKey = "k" },
            expected: .secret(section: "zai", key: "api_key", plaintext: "k")),
        Row(section: "zai", field: "planTier", mutate: { $0.zai.planTier = "pro" },
            expected: .string(section: "zai", key: "plan_tier", value: "pro")),
        // [openrouter]
        Row(section: "openrouter", field: "enabled", mutate: { $0.openrouter.enabled = false },
            expected: .bool(section: "openrouter", key: "enabled", value: false)),
        Row(section: "openrouter", field: "apiKeyEnv", mutate: { $0.openrouter.apiKeyEnv = "ENV_OR" },
            expected: .string(section: "openrouter", key: "api_key_env", value: "ENV_OR")),
        Row(section: "openrouter", field: "apiKey", mutate: { $0.openrouter.apiKey = "k" },
            expected: .secret(section: "openrouter", key: "api_key", plaintext: "k")),
        // [kimi]
        Row(section: "kimi", field: "enabled", mutate: { $0.kimi.enabled = false },
            expected: .bool(section: "kimi", key: "enabled", value: false)),
        Row(section: "kimi", field: "apiKeyEnv", mutate: { $0.kimi.apiKeyEnv = "ENV_K" },
            expected: .string(section: "kimi", key: "api_key_env", value: "ENV_K")),
        Row(section: "kimi", field: "apiKey", mutate: { $0.kimi.apiKey = "k" },
            expected: .secret(section: "kimi", key: "api_key", plaintext: "k")),
        Row(section: "kimi", field: "baseURL", mutate: { $0.kimi.baseURL = "https://api.moonshot.cn/v1" },
            expected: .string(section: "kimi", key: "base_url", value: "https://api.moonshot.cn/v1")),
        // [gemini]
        Row(section: "gemini", field: "enabled", mutate: { $0.gemini.enabled = false },
            expected: .bool(section: "gemini", key: "enabled", value: false)),
        Row(section: "gemini", field: "apiKeyEnv", mutate: { $0.gemini.apiKeyEnv = "ENV_G" },
            expected: .string(section: "gemini", key: "api_key_env", value: "ENV_G")),
        Row(section: "gemini", field: "apiKey", mutate: { $0.gemini.apiKey = "k" },
            expected: .secret(section: "gemini", key: "api_key", plaintext: "k")),
        Row(section: "gemini", field: "agyPath", mutate: { $0.gemini.agyPath = "/opt/agy" },
            expected: .string(section: "gemini", key: "agy_path", value: "/opt/agy")),
        Row(section: "gemini", field: "preferAntigravity", mutate: { $0.gemini.preferAntigravity = false },
            expected: .bool(section: "gemini", key: "prefer_antigravity", value: false)),
        Row(section: "gemini", field: "baseURL",
            mutate: { $0.gemini.baseURL = "https://generativelanguage.googleapis.com/v1" },
            expected: .string(section: "gemini", key: "base_url",
                              value: "https://generativelanguage.googleapis.com/v1")),
        // [deepseek]
        Row(section: "deepseek", field: "enabled", mutate: { $0.deepseek.enabled = false },
            expected: .bool(section: "deepseek", key: "enabled", value: false)),
        Row(section: "deepseek", field: "apiKeyEnv", mutate: { $0.deepseek.apiKeyEnv = "ENV_D" },
            expected: .string(section: "deepseek", key: "api_key_env", value: "ENV_D")),
        Row(section: "deepseek", field: "apiKey", mutate: { $0.deepseek.apiKey = "k" },
            expected: .secret(section: "deepseek", key: "api_key", plaintext: "k")),
        Row(section: "deepseek", field: "baseURL", mutate: { $0.deepseek.baseURL = "https://api.deepseek.com/v1" },
            expected: .string(section: "deepseek", key: "base_url", value: "https://api.deepseek.com/v1")),
        // [typesafe] — disabled by default, so the enabled row turns it ON;
        // saving a key also switches it on (SDD §4.3).
        Row(section: "typesafe", field: "enabled", mutate: { $0.typesafe.enabled = true },
            expected: .bool(section: "typesafe", key: "enabled", value: true)),
        Row(section: "typesafe", field: "apiKeyEnv", mutate: { $0.typesafe.apiKeyEnv = "ENV_T" },
            expected: .string(section: "typesafe", key: "api_key_env", value: "ENV_T")),
        Row(section: "typesafe", field: "apiKey", mutate: { $0.typesafe.apiKey = "k" },
            expected: .secret(section: "typesafe", key: "api_key", plaintext: "k"),
            expectedAll: [.bool(section: "typesafe", key: "enabled", value: true),
                          .secret(section: "typesafe", key: "api_key", plaintext: "k")]),
        Row(section: "typesafe", field: "baseURL", mutate: { $0.typesafe.baseURL = "https://api.typesafe.ai/" },
            expected: .string(section: "typesafe", key: "base_url", value: "https://api.typesafe.ai/")),
        // [xai]
        Row(section: "xai", field: "enabled", mutate: { $0.xai.enabled = false },
            expected: .bool(section: "xai", key: "enabled", value: false)),
        Row(section: "xai", field: "preferGrokCLI", mutate: { $0.xai.preferGrokCLI = false },
            expected: .bool(section: "xai", key: "prefer_grok_cli", value: false)),
        Row(section: "xai", field: "grokAuthPath", mutate: { $0.xai.grokAuthPath = "/tmp/grok.json" },
            expected: .string(section: "xai", key: "grok_auth_path", value: "/tmp/grok.json")),
        Row(section: "xai", field: "grokBaseURL",
            mutate: { $0.xai.grokBaseURL = "https://cli-chat-proxy.grok.com/v2" },
            expected: .string(section: "xai", key: "grok_base_url", value: "https://cli-chat-proxy.grok.com/v2")),
        Row(section: "xai", field: "apiKeyEnv", mutate: { $0.xai.apiKeyEnv = "ENV_X" },
            expected: .string(section: "xai", key: "api_key_env", value: "ENV_X")),
        Row(section: "xai", field: "apiKey", mutate: { $0.xai.apiKey = "k" },
            expected: .secret(section: "xai", key: "api_key", plaintext: "k")),
        Row(section: "xai", field: "teamId", mutate: { $0.xai.teamId = "team" },
            expected: .string(section: "xai", key: "team_id", value: "team")),
        Row(section: "xai", field: "baseURL", mutate: { $0.xai.baseURL = "https://management-api.x.ai/v2" },
            expected: .string(section: "xai", key: "base_url", value: "https://management-api.x.ai/v2")),
    ]

    @Test("identical configs produce no changes")
    func identical_is_empty() {
        #expect(SettingsViewModel.diff(from: AppConfig(), to: AppConfig()).isEmpty)
    }

    @Test("each single-field change emits exactly its ConfigChange", arguments: rows)
    func single_field_change(_ row: Row) {
        var changed = AppConfig()
        row.mutate(&changed)
        #expect(SettingsViewModel.diff(from: AppConfig(), to: changed) == (row.expectedAll ?? [row.expected]))
    }

    @Test("every AppConfig section is covered by the rows")
    func every_section_covered() {
        let sections = Set(Mirror(reflecting: AppConfig()).children.compactMap(\.label))
        #expect(Set(Self.rows.map(\.section)) == sections)
    }

    /// Fields another writer owns: the in-app TypeSafe sign-in writes its
    /// session itself (`TypeSafeLoginController`), so a Settings save built
    /// from a draft loaded earlier must never overwrite or clear it.
    static let notDiffed: [String: Set<String>] = [
        "typesafe": ["consoleSession", "consoleSessionExpiresAt"],
    ]

    @Test("every stored field of every section is covered by the rows")
    func every_field_covered() {
        for child in Mirror(reflecting: AppConfig()).children {
            guard let section = child.label else { continue }
            let fields = Set(Mirror(reflecting: child.value).children.compactMap(\.label))
                .subtracting(Self.notDiffed[section] ?? [])
            let listed = Set(Self.rows.filter { $0.section == section }.map(\.field))
            #expect(listed == fields, "section [\(section)]")
        }
    }

    @Test("a Settings save never touches the TypeSafe console session")
    func typesafe_session_not_diffed() {
        var signedIn = AppConfig()
        signedIn.typesafe.consoleSession = "session=a; session_id=b; organization_id=c"
        signedIn.typesafe.consoleSessionExpiresAt = 1_790_000_000
        #expect(SettingsViewModel.diff(from: AppConfig(), to: signedIn).isEmpty)
        #expect(SettingsViewModel.diff(from: signedIn, to: AppConfig()).isEmpty)
    }

    @Test("saving a TypeSafe key enables it; clearing the key does not disable it")
    func typesafe_key_save_enables() {
        let off = TypeSafeConfig()
        var withKey = off
        withKey.apiKey = "ts-key"
        #expect(SettingsViewModel.typeSafeAfterSave(old: off, new: withKey).enabled)

        var blank = off
        blank.apiKey = "   "
        #expect(!SettingsViewModel.typeSafeAfterSave(old: off, new: blank).enabled)

        var onWithKey = TypeSafeConfig(enabled: true, apiKey: "ts-key")
        onWithKey.apiKey = nil
        #expect(SettingsViewModel.typeSafeAfterSave(old: TypeSafeConfig(enabled: true, apiKey: "ts-key"),
                                                    new: onWithKey).enabled)

        // Unchanged key never flips a deliberately disabled provider back on.
        let keptOff = TypeSafeConfig(enabled: false, apiKey: "ts-key")
        #expect(!SettingsViewModel.typeSafeAfterSave(old: keptOff, new: keptOff).enabled)
    }
}
