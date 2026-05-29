import Foundation
import TOMLKit

public struct ConfigLoader: Sendable {
    public let path: URL

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
        do {
            let decoder = TOMLDecoder()
            return try decoder.decode(AppConfig.self, from: raw)
        } catch {
            throw AppError.toml("parse \(path.path): \(error)")
        }
    }

    public func save(_ config: AppConfig) throws {
        do {
            let encoder = TOMLEncoder()
            let s = try encoder.encode(config)
            // config.toml may contain inline `api_key = "..."` — lock it down
            // to user-only at write time.
            try AtomicFileWrite.write(Data(s.utf8), to: path, permissions: 0o600)
        } catch {
            throw AppError.toml("encode config.toml: \(error)")
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
        # refresh_interval_seconds = 150    # default 150 (2.5m). Floor 15. Common: 60, 150, 300, 600.
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
        # pin_hosts = ["api.anthropic.com", "chatgpt.com", "openrouter.ai", "api.z.ai", "api.moonshot.ai"]
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

        """),
        ("[openai]", """

        [openai]
        enabled = true

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
    ]
}
