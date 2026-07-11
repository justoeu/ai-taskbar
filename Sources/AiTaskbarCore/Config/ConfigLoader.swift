import Foundation
import TOMLKit

/// One atomic edit to a field in `config.toml`. `ConfigLoader.applyChanges`
/// accepts a batch of these and applies them via `TOMLEditor` (comment-
/// preserving surgical edit). The `secret` case envelopes the value with
/// `SecretBox.encrypt` before it hits disk.
public enum ConfigChange: Sendable, Equatable {
    case double(section: String, key: String, value: Double)
    case bool(section: String, key: String, value: Bool)
    /// String value. Nil writes `""` (semantically equivalent to "cleared"
    /// for all Optional<String> fields in the AppConfig schema).
    case string(section: String, key: String, value: String?)
    case stringArray(section: String, key: String, value: [String])
    /// Plaintext secret. Nil clears the slot. Non-nil is auto-encrypted
    /// before write.
    case secret(section: String, key: String, plaintext: String?)

    public var section: String {
        switch self {
        case .double(let s, _, _),
             .bool(let s, _, _),
             .string(let s, _, _),
             .stringArray(let s, _, _),
             .secret(let s, _, _):
            return s
        }
    }

    public var key: String {
        switch self {
        case .double(_, let k, _),
             .bool(_, let k, _),
             .string(_, let k, _),
             .stringArray(_, let k, _),
             .secret(_, let k, _):
            return k
        }
    }
}

public struct ConfigLoader: Sendable {
    public let path: URL

    /// Hook invoked AFTER a successful write (save/applyChanges) but BEFORE
    /// control returns to the caller. The Settings UI uses this to call
    /// `ConfigWatcher.adoptCurrentAsBaseline()` so the user doesn't see the
    /// yellow "Config changed — relaunch" banner for an edit they just made
    /// through the app itself. Defaults to no-op.
    public var onAfterSave: @Sendable () -> Void = {}

    /// Use when you have an explicit path (tests, fallback). Statically
    /// non-throwing — separating from the default-path init avoids the
    /// previous `try!` smell in `AppEnvironment.live()`'s fallback branch.
    public init(path: URL) {
        self.path = path
    }

    /// Default location: `~/Library/Application Support/ai-taskbar/config.toml`.
    /// Can throw if the Application Support dir can't be created.
    public init() throws {
        self.path = try Paths.configFile()
    }

    public func load() throws -> AppConfig {
        if !FileManager.default.fileExists(atPath: path.path) {
            return AppConfig()
        }
        // Retroactively tighten perms on files created before we started
        // chmod'ing — best-effort, doesn't fail load if it can't.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: path.path
        )
        let raw: String
        do {
            raw = try String(contentsOf: path, encoding: .utf8)
        } catch {
            throw AppError.io("read config.toml: \(error)")
        }
        var config: AppConfig
        do {
            let decoder = TOMLDecoder()
            config = try decoder.decode(AppConfig.self, from: raw)
        } catch {
            throw AppError.toml("parse \(path.path): \(error)")
        }
        // Transparently decrypt any `enc:v1:`-prefixed `api_key` values the
        // Settings UI wrote. Plaintext values pass through unchanged — keeps
        // backward compatibility with configs written before this UI existed.
        Self.decryptSecrets(in: &config)
        return config
    }

    public func save(_ config: AppConfig) throws {
        do {
            let encoder = TOMLEncoder()
            let s = try encoder.encode(config)
            // config.toml may contain inline `api_key = "..."` — lock it down
            // to user-only at write time.
            try AtomicFileWrite.write(Data(s.utf8), to: path, permissions: 0o600)
            onAfterSave()
        } catch {
            throw AppError.toml("encode config.toml: \(error)")
        }
    }

    /// Surgical write path: applies a batch of changes to the existing file
    /// via `TOMLEditor.setValue`, preserving every comment, blank line, and
    /// unknown key. Used by the Settings UI so hand-written annotations in
    /// `config.toml` survive an edit done through the app. If the file
    /// doesn't exist yet, bootstraps it from the default-snippet table.
    ///
    /// `secret` changes are auto-encrypted via `SecretBox` (so the on-disk
    /// value is `enc:v1:...`, not plaintext). Other types are written as
    /// plain TOML literals.
    public func applyChanges(_ changes: [ConfigChange]) throws {
        var content: String
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                content = try String(contentsOf: path, encoding: .utf8)
            } catch {
                throw AppError.io("read config.toml for edit: \(error)")
            }
        } else {
            // First-write bootstrap: start from defaults so the file has the
            // full schema (preserving comments in the snippet table).
            content = Self.defaultSnippets.map { $0.snippet }.joined()
        }

        for change in changes {
            let encoded: TOMLEditor.EncodedValue
            switch change {
            case .double(_, _, let v):       encoded = .double(v)
            case .bool(_, _, let v):         encoded = .bool(v)
            case .string(_, _, let v?):
                // Empty string clears the slot — write as "" so the decoder's
                // `decodeIfPresent` reads it as missing. (TOML `""` decodes
                // as a valid empty String, which the config loader treats
                // equivalently to nil for the api_key_env-shaped fields.)
                encoded = .string(v)
            case .string(_, _, nil):
                // Removing a key entirely is harder (line deletion) — for the
                // Settings UI v1 we write the empty literal, which has the
                // same semantic effect for every Optional<String> in the schema.
                encoded = .string("")
            case .stringArray(_, _, let v):  encoded = .stringArray(v)
            case .secret(_, _, let plaintext?):
                let enc = try SecretBox.encrypt(plaintext)
                encoded = .encrypted(enc)
            case .secret(_, _, nil):
                // Clear secret = empty string slot.
                encoded = .string("")
            }
            do {
                content = try TOMLEditor.setValue(
                    in: content, section: change.section, key: change.key, value: encoded)
            } catch {
                throw AppError.toml("applyChanges [\(change.section).\(change.key)]: \(error)")
            }
        }

        try AtomicFileWrite.write(Data(content.utf8), to: path, permissions: 0o600)
        onAfterSave()
    }

    /// Walks the four vendor configs that support inline `api_key`, replacing
    /// any `enc:v1:`-prefixed value with its decrypted plaintext. Plaintext
    /// values pass through unchanged. Tampered ciphertext is logged + the
    /// key cleared (rather than taking down the whole config load) so a
    /// single corrupted line doesn't lock the user out.
    private static func decryptSecrets(in config: inout AppConfig) {
        if let enc = config.zai.apiKey, SecretBox.isEncrypted(enc) {
            if let pt = try? SecretBox.decryptIfPresent(enc) ?? nil {
                config.zai.apiKey = pt
            } else {
                AppLog.config.warning("zai.api_key encrypted but undecryptable — clearing")
                config.zai.apiKey = nil
            }
        }
        if let enc = config.openrouter.apiKey, SecretBox.isEncrypted(enc) {
            if let pt = try? SecretBox.decryptIfPresent(enc) ?? nil {
                config.openrouter.apiKey = pt
            } else {
                AppLog.config.warning("openrouter.api_key encrypted but undecryptable — clearing")
                config.openrouter.apiKey = nil
            }
        }
        if let enc = config.kimi.apiKey, SecretBox.isEncrypted(enc) {
            if let pt = try? SecretBox.decryptIfPresent(enc) ?? nil {
                config.kimi.apiKey = pt
            } else {
                AppLog.config.warning("kimi.api_key encrypted but undecryptable — clearing")
                config.kimi.apiKey = nil
            }
        }
        if let enc = config.gemini.apiKey, SecretBox.isEncrypted(enc) {
            if let pt = try? SecretBox.decryptIfPresent(enc) ?? nil {
                config.gemini.apiKey = pt
            } else {
                AppLog.config.warning("gemini.api_key encrypted but undecryptable — clearing")
                config.gemini.apiKey = nil
            }
        }
        if let enc = config.deepseek.apiKey, SecretBox.isEncrypted(enc) {
            if let pt = try? SecretBox.decryptIfPresent(enc) ?? nil {
                config.deepseek.apiKey = pt
            } else {
                AppLog.config.warning("deepseek.api_key encrypted but undecryptable — clearing")
                config.deepseek.apiKey = nil
            }
        }
        if let enc = config.xai.apiKey, SecretBox.isEncrypted(enc) {
            if let pt = try? SecretBox.decryptIfPresent(enc) ?? nil {
                config.xai.apiKey = pt
            } else {
                AppLog.config.warning("xai.api_key encrypted but undecryptable — clearing")
                config.xai.apiKey = nil
            }
        }
    }

    /// Idempotently appends any vendor section that's missing from the user's
    /// config file. Preserves all existing content (including comments) — we
    /// only add what isn't already there, never rewrite what is.
    /// Returns the list of section headers that were appended, if any.
    @discardableResult
    public func ensureAllVendorSections() throws -> [String] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        var appended: [String] = []
        var addition = ""

        for (header, snippet) in Self.defaultSnippets {
            if !existing.contains(header) {
                addition += snippet
                appended.append(header)
            }
        }
        guard !addition.isEmpty else { return [] }

        let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
        let updated = existing + separator + addition
        try AtomicFileWrite.write(Data(updated.utf8), to: path, permissions: 0o600)
        return appended
    }

    /// Default TOML snippet appended for each vendor when missing. Keep in
    /// sync with `config.example.toml` so users see the same content either
    /// way.
    private static let defaultSnippets: [(header: String, snippet: String)] = [
        ("[ui]", """

        [ui]
        # primary = "anthropic"             # which tab opens first
        # menu_bar_mode = "icon_and_percent"  # icon | icon_and_percent | rotating
        # refresh_interval_seconds = 300    # default 300 (5m). Floor 15. Common: 60, 150, 300, 600.
        # language = "pt-BR"                # force UI language (en | pt-BR | es). Default: system locale.

        """),
        ("[thresholds]", """

        [thresholds]
        warning  = 70
        critical = 90

        """),
        ("[notifications]", """

        [notifications]
        enabled   = true
        notify_at = [90, 100]
        # discreet = true   # hides vendor name from notification title (lock-screen friendly)

        """),
        ("[security]", """

        [security]
        # TLS pinning (SPKI hash, Trust-On-First-Use). Empty list = no pinning.
        # pin_hosts = ["api.anthropic.com", "chatgpt.com", "openrouter.ai", "api.z.ai", "api.moonshot.ai", "api.deepseek.com", "management-api.x.ai"]
        # pin_audit_only = false

        """),
        ("[updates]", """

        [updates]
        # Default points at the upstream repo. Override if you forked.
        # enabled = true
        # owner_repo = "justoeu/ai-taskbar"
        # include_prereleases = false

        """),
        ("[anthropic]", """

        [anthropic]
        enabled = true
        # keychain_account = "your.short.username"   # pin if you have multiple Claude entries
        # manage_oauth_refresh = false   # default false: read-only, let Claude Code own token renewal.
        #                                 # Set true ONLY if you run the app without the Claude Code CLI;
        #                                 # true rotates the shared token and can log out other CLI sessions.

        """),
        ("[openai]", """

        [openai]
        enabled = true
        # manage_oauth_refresh = false   # default false: read-only, let the Codex CLI own token renewal.
        #                                 # Set true ONLY if you run the app without the Codex CLI;
        #                                 # true rotates the shared token and can log out other CLI sessions.

        """),
        ("[openrouter]", """

        [openrouter]
        enabled     = true
        api_key_env = "OPENROUTER_API_KEY"
        # api_key   = "sk-or-v1-..."

        """),
        ("[zai]", """

        [zai]
        enabled     = true
        api_key_env = "ZAI_API_KEY"
        # api_key   = "..."

        """),
        ("[kimi]", """

        [kimi]
        enabled     = true
        api_key_env = "MOONSHOT_API_KEY"
        # api_key   = "sk-..."
        # base_url  = "https://api.moonshot.ai/v1"   # use https://api.moonshot.cn/v1 for China region

        """),
        ("[gemini]", """

        [gemini]
        enabled     = true
        api_key_env = "GEMINI_API_KEY"
        # api_key   = "AIza..."
        # base_url  = "https://generativelanguage.googleapis.com/v1beta"

        """),
        ("[deepseek]", """

        [deepseek]
        enabled     = true
        api_key_env = "DEEPSEEK_API_KEY"
        # api_key   = "sk-..."
        # base_url  = "https://api.deepseek.com"

        """),
        ("[xai]", """

        [xai]
        enabled     = true
        api_key_env = "XAI_MANAGEMENT_KEY"
        # api_key   = "xai-..."          # management key (NOT the inference key)
        # team_id   = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        # base_url  = "https://management-api.x.ai"

        """),
    ]
}
