import Foundation
import SwiftUI
import AiTaskbarCore

/// Drives the Settings UI. Holds a working copy of `AppConfig` that SwiftUI
/// binds to (`draft`), computes a diff against the snapshot captured at open
/// time (`original`), and feeds that diff to `ConfigLoader.applyChanges`
/// (comment-preserving surgical write). After save, fires a "relaunch to
/// apply" banner so the user knows most config changes require restart
/// (provider graph is built once at launch).
@MainActor
public final class SettingsViewModel: ObservableObject {
    /// Working copy the form binds to. Mutated by SwiftUI Bindings as the
    /// user edits. Compared against `original` on `save()` to build the diff.
    @Published public var draft: AppConfig

    /// Surfaces a save-time error to the form. Cleared on next successful
    /// save or on `discardChanges()`.
    @Published public var saveError: String?

    /// Set to `true` after a successful save. The popover observes this and
    /// flips the existing "Config changed — relaunch" banner on so the user
    /// sees the post-save UX consistently with manual file edits.
    @Published public var didSaveSuccessfully = false

    /// Snapshot at open time. Used to compute the diff on save.
    private let original: AppConfig

    /// The loader that owns `config.toml`. Wires `onAfterSave` so the
    /// `ConfigWatcher` doesn't trigger its banner for our own write (we
    /// surface the banner ourselves via `didSaveSuccessfully`).
    private let configLoader: ConfigLoader

    public init(config: AppConfig, configLoader: ConfigLoader) {
        self.original = config
        self.draft = config
        self.configLoader = configLoader
    }

    /// True when `draft != original` — drives the Save button's enabled
    /// state in the form footer.
    public var hasUnsavedChanges: Bool {
        draft != original
    }

    /// Reverts `draft` back to `original`. Use when the user cancels.
    public func discardChanges() {
        draft = original
        saveError = nil
    }

    /// Writes the diff between `draft` and `original` to disk via the
    /// comment-preserving surgical path. Throws on TOML errors so the form
    /// can surface them — does NOT clear `saveError` on partial failure.
    /// TypeSafe starts disabled and is switched on by saving a key: a newly
    /// entered, non-empty inline key enables it in the same write. Clearing
    /// the key does NOT disable it (the user may rely on `TYPESAFE_API_KEY`);
    /// the Enabled toggle does that.
    static func typeSafeAfterSave(old: TypeSafeConfig, new: TypeSafeConfig) -> TypeSafeConfig {
        var out = new
        let key = new.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty, new.apiKey != old.apiKey {
            out.enabled = true
        }
        return out
    }

    public func save() throws {
        let changes = Self.diff(from: original, to: draft)
        if changes.isEmpty {
            // Nothing changed — nothing to write, no banner needed.
            return
        }
        do {
            try configLoader.applyChanges(changes)
            saveError = nil
            didSaveSuccessfully = true
        } catch {
            saveError = "\(error)"
            throw error
        }
    }

    /// Full-reset path: blows away the user's `config.toml` and writes a
    /// clean default-encoded version. Comments are lost (acceptable on a
    /// destructive reset). Requires confirmation in the UI before calling.
    /// Where "Restore defaults" saved the previous file (nil before any).
    @Published public private(set) var lastResetBackup: URL?

    /// Rewrites config.toml from defaults — but only after a dated 0600 copy
    /// of the current file exists: the rewrite drops every inline API key and
    /// the TypeSafe session, and before this nothing could bring them back.
    public func resetToDefaults() throws {
        do {
            lastResetBackup = try configLoader.backupCurrentFile()
            try configLoader.save(AppConfig())
            saveError = nil
            didSaveSuccessfully = true
        } catch {
            saveError = "\(error)"
            throw error
        }
    }

    // MARK: - Diff

    /// Walks both AppConfigs field-by-field and produces a list of
    /// `ConfigChange` entries covering every differing value. Secret-shaped
    /// fields (the four vendor `api_key`s) become `.secret` entries that
    /// `ConfigLoader.applyChanges` will auto-encrypt.
    ///
    /// Designed to be exhaustive — forgetting to diff a new field silently
    /// breaks the Settings UI. If you add a field to a config struct, add
    /// its diff case here; `SettingsViewModelDiffTests` enforces this via
    /// `Mirror` and fails until the new field is diffed and listed.
    static func diff(from old: AppConfig, to new: AppConfig) -> [ConfigChange] {
        var out: [ConfigChange] = []

        // [ui]
        if old.ui.primary != new.ui.primary {
            out.append(.string(section: "ui", key: "primary",
                               value: new.ui.primary?.rawValue))
        }
        if old.ui.menuBarMode != new.ui.menuBarMode {
            out.append(.string(section: "ui", key: "menu_bar_mode",
                               value: new.ui.menuBarMode.rawValue))
        }
        if old.ui.refreshIntervalSeconds != new.ui.refreshIntervalSeconds {
            out.append(.double(section: "ui", key: "refresh_interval_seconds",
                               value: new.ui.refreshIntervalSeconds))
        }
        if old.ui.language != new.ui.language {
            out.append(.string(section: "ui", key: "language", value: new.ui.language))
        }

        // [thresholds]
        if old.thresholds.warning != new.thresholds.warning {
            out.append(.double(section: "thresholds", key: "warning",
                               value: new.thresholds.warning))
        }
        if old.thresholds.critical != new.thresholds.critical {
            out.append(.double(section: "thresholds", key: "critical",
                               value: new.thresholds.critical))
        }

        // [notifications]
        if old.notifications.enabled != new.notifications.enabled {
            out.append(.bool(section: "notifications", key: "enabled",
                             value: new.notifications.enabled))
        }
        if old.notifications.notifyAt != new.notifications.notifyAt {
            // Unquoted TOML numbers (`[80, 95]`). stringArray would write
            // `["80", "95"]` which flexibleDoubleArray cannot decode and
            // silently falls back to defaults (BUG-ART-001).
            out.append(.doubleArray(section: "notifications", key: "notify_at",
                                    value: new.notifications.notifyAt))
        }
        if old.notifications.discreet != new.notifications.discreet {
            out.append(.bool(section: "notifications", key: "discreet",
                             value: new.notifications.discreet))
        }

        // [security]
        if old.security.pinHosts != new.security.pinHosts {
            out.append(.stringArray(section: "security", key: "pin_hosts",
                                    value: new.security.pinHosts))
        }
        if old.security.pinAuditOnly != new.security.pinAuditOnly {
            out.append(.bool(section: "security", key: "pin_audit_only",
                             value: new.security.pinAuditOnly))
        }

        // [updates]
        if old.updates.enabled != new.updates.enabled {
            out.append(.bool(section: "updates", key: "enabled",
                             value: new.updates.enabled))
        }
        if old.updates.ownerRepo != new.updates.ownerRepo {
            out.append(.string(section: "updates", key: "owner_repo",
                               value: new.updates.ownerRepo))
        }
        if old.updates.includePrereleases != new.updates.includePrereleases {
            out.append(.bool(section: "updates", key: "include_prereleases",
                             value: new.updates.includePrereleases))
        }

        // [anthropic]
        if old.anthropic.enabled != new.anthropic.enabled {
            out.append(.bool(section: "anthropic", key: "enabled",
                             value: new.anthropic.enabled))
        }
        if old.anthropic.keychainService != new.anthropic.keychainService {
            out.append(.string(section: "anthropic", key: "keychain_service",
                               value: new.anthropic.keychainService))
        }
        if old.anthropic.keychainAccount != new.anthropic.keychainAccount {
            out.append(.string(section: "anthropic", key: "keychain_account",
                               value: new.anthropic.keychainAccount))
        }
        if old.anthropic.manageOAuthRefresh != new.anthropic.manageOAuthRefresh {
            out.append(.bool(section: "anthropic", key: "manage_oauth_refresh",
                             value: new.anthropic.manageOAuthRefresh))
        }

        // [openai]
        if old.openai.enabled != new.openai.enabled {
            out.append(.bool(section: "openai", key: "enabled",
                             value: new.openai.enabled))
        }
        if old.openai.codexAuthPath != new.openai.codexAuthPath {
            out.append(.string(section: "openai", key: "codex_auth_path",
                               value: new.openai.codexAuthPath))
        }
        if old.openai.manageOAuthRefresh != new.openai.manageOAuthRefresh {
            out.append(.bool(section: "openai", key: "manage_oauth_refresh",
                             value: new.openai.manageOAuthRefresh))
        }

        // [zai]
        if old.zai.enabled != new.zai.enabled {
            out.append(.bool(section: "zai", key: "enabled", value: new.zai.enabled))
        }
        if old.zai.apiKeyEnv != new.zai.apiKeyEnv {
            out.append(.string(section: "zai", key: "api_key_env", value: new.zai.apiKeyEnv))
        }
        if old.zai.apiKey != new.zai.apiKey {
            out.append(.secret(section: "zai", key: "api_key", plaintext: new.zai.apiKey))
        }
        if old.zai.planTier != new.zai.planTier {
            out.append(.string(section: "zai", key: "plan_tier", value: new.zai.planTier))
        }

        // [openrouter]
        if old.openrouter.enabled != new.openrouter.enabled {
            out.append(.bool(section: "openrouter", key: "enabled", value: new.openrouter.enabled))
        }
        if old.openrouter.apiKeyEnv != new.openrouter.apiKeyEnv {
            out.append(.string(section: "openrouter", key: "api_key_env", value: new.openrouter.apiKeyEnv))
        }
        if old.openrouter.apiKey != new.openrouter.apiKey {
            out.append(.secret(section: "openrouter", key: "api_key", plaintext: new.openrouter.apiKey))
        }

        // [kimi]
        if old.kimi.enabled != new.kimi.enabled {
            out.append(.bool(section: "kimi", key: "enabled", value: new.kimi.enabled))
        }
        if old.kimi.apiKeyEnv != new.kimi.apiKeyEnv {
            out.append(.string(section: "kimi", key: "api_key_env", value: new.kimi.apiKeyEnv))
        }
        if old.kimi.apiKey != new.kimi.apiKey {
            out.append(.secret(section: "kimi", key: "api_key", plaintext: new.kimi.apiKey))
        }
        if old.kimi.baseURL != new.kimi.baseURL {
            out.append(.string(section: "kimi", key: "base_url", value: new.kimi.baseURL))
        }

        // [gemini]
        if old.gemini.enabled != new.gemini.enabled {
            out.append(.bool(section: "gemini", key: "enabled", value: new.gemini.enabled))
        }
        if old.gemini.apiKeyEnv != new.gemini.apiKeyEnv {
            out.append(.string(section: "gemini", key: "api_key_env", value: new.gemini.apiKeyEnv))
        }
        if old.gemini.apiKey != new.gemini.apiKey {
            out.append(.secret(section: "gemini", key: "api_key", plaintext: new.gemini.apiKey))
        }
        if old.gemini.baseURL != new.gemini.baseURL {
            out.append(.string(section: "gemini", key: "base_url", value: new.gemini.baseURL))
        }
        if old.gemini.agyPath != new.gemini.agyPath {
            out.append(.string(section: "gemini", key: "agy_path", value: new.gemini.agyPath))
        }
        if old.gemini.preferAntigravity != new.gemini.preferAntigravity {
            out.append(.bool(section: "gemini", key: "prefer_antigravity", value: new.gemini.preferAntigravity))
        }

        // [deepseek]
        if old.deepseek.enabled != new.deepseek.enabled {
            out.append(.bool(section: "deepseek", key: "enabled", value: new.deepseek.enabled))
        }
        if old.deepseek.apiKeyEnv != new.deepseek.apiKeyEnv {
            out.append(.string(section: "deepseek", key: "api_key_env", value: new.deepseek.apiKeyEnv))
        }
        if old.deepseek.apiKey != new.deepseek.apiKey {
            out.append(.secret(section: "deepseek", key: "api_key", plaintext: new.deepseek.apiKey))
        }
        if old.deepseek.baseURL != new.deepseek.baseURL {
            out.append(.string(section: "deepseek", key: "base_url", value: new.deepseek.baseURL))
        }

        // [typesafe] — saving a key is what switches the provider on
        // (docs/SDD-typesafe-jev.md §4.3).
        let ts = Self.typeSafeAfterSave(old: old.typesafe, new: new.typesafe)
        if old.typesafe.enabled != ts.enabled {
            out.append(.bool(section: "typesafe", key: "enabled", value: ts.enabled))
        }
        if old.typesafe.apiKeyEnv != ts.apiKeyEnv {
            out.append(.string(section: "typesafe", key: "api_key_env", value: ts.apiKeyEnv))
        }
        if old.typesafe.apiKey != ts.apiKey {
            out.append(.secret(section: "typesafe", key: "api_key", plaintext: ts.apiKey))
        }
        if old.typesafe.baseURL != ts.baseURL {
            out.append(.string(section: "typesafe", key: "base_url", value: ts.baseURL))
        }

        // [xai]
        if old.xai.enabled != new.xai.enabled {
            out.append(.bool(section: "xai", key: "enabled", value: new.xai.enabled))
        }
        if old.xai.preferGrokCLI != new.xai.preferGrokCLI {
            out.append(.bool(section: "xai", key: "prefer_grok_cli", value: new.xai.preferGrokCLI))
        }
        if old.xai.grokAuthPath != new.xai.grokAuthPath {
            out.append(.string(section: "xai", key: "grok_auth_path", value: new.xai.grokAuthPath ?? ""))
        }
        if old.xai.grokBaseURL != new.xai.grokBaseURL {
            out.append(.string(section: "xai", key: "grok_base_url", value: new.xai.grokBaseURL))
        }
        if old.xai.apiKeyEnv != new.xai.apiKeyEnv {
            out.append(.string(section: "xai", key: "api_key_env", value: new.xai.apiKeyEnv))
        }
        if old.xai.apiKey != new.xai.apiKey {
            out.append(.secret(section: "xai", key: "api_key", plaintext: new.xai.apiKey))
        }
        if old.xai.teamId != new.xai.teamId {
            out.append(.string(section: "xai", key: "team_id", value: new.xai.teamId))
        }
        if old.xai.baseURL != new.xai.baseURL {
            out.append(.string(section: "xai", key: "base_url", value: new.xai.baseURL))
        }

        return out
    }
}
