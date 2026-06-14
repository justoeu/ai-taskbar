import Testing
import Foundation
import TOMLKit
@testable import AiTaskbarCore

@Suite("AppConfig TOML parsing")
struct AppConfigTests {
    @Test("missing sections fall back to defaults")
    func missing_sections_fall_back_to_defaults() throws {
        let toml = #"""
        [ui]
        primary = "openai"
        """#
        let cfg = try TOMLDecoder().decode(AppConfig.self, from: toml)
        #expect(cfg.ui.primary == .openai)
        #expect(cfg.anthropic.enabled)
        // Read-only is the safe default: the monitor must not rotate the
        // shared Claude Code / Codex OAuth tokens unless explicitly opted in.
        #expect(cfg.anthropic.manageOAuthRefresh == false)
        #expect(cfg.openai.manageOAuthRefresh == false)
        #expect(cfg.zai.apiKeyEnv == "ZAI_API_KEY")
    }

    @Test("full round trip preserves vendor settings")
    func full_round_trip() throws {
        let toml = #"""
        [ui]
        primary = "zai"

        [anthropic]
        enabled = false
        manage_oauth_refresh = true

        [openai]
        enabled = true
        codex_auth_path = "/tmp/auth.json"
        manage_oauth_refresh = true

        [zai]
        enabled = true
        api_key_env = "ZAI_KEY"
        api_key = "abc"
        plan_tier = "pro"

        [openrouter]
        enabled = false
        api_key_env = "OPENROUTER"
        """#
        let cfg = try TOMLDecoder().decode(AppConfig.self, from: toml)
        #expect(cfg.ui.primary == .zai)
        #expect(!cfg.anthropic.enabled)
        #expect(cfg.anthropic.manageOAuthRefresh == true)
        #expect(cfg.openai.codexAuthPath == "/tmp/auth.json")
        #expect(cfg.openai.manageOAuthRefresh == true)
        #expect(cfg.zai.apiKey == "abc")
        #expect(cfg.zai.planTier == "pro")
        #expect(!cfg.openrouter.enabled)
    }

    @Test("refresh interval defaults to 300s")
    func refresh_interval_default() throws {
        let cfg = try TOMLDecoder().decode(AppConfig.self, from: "")
        #expect(cfg.ui.refreshIntervalSeconds == 300)
    }

    @Test("refresh interval accepts int and float (TOML lenient decode)")
    func refresh_interval_accepts_int_and_float() throws {
        let asInt = "[ui]\nrefresh_interval_seconds = 90\n"
        let asFloat = "[ui]\nrefresh_interval_seconds = 90.5\n"
        let cfgInt = try TOMLDecoder().decode(AppConfig.self, from: asInt)
        let cfgFloat = try TOMLDecoder().decode(AppConfig.self, from: asFloat)
        #expect(cfgInt.ui.refreshIntervalSeconds == 90)
        #expect(cfgFloat.ui.refreshIntervalSeconds == 90.5)
    }

    @Test("thresholds accept int array (warns/critical from TOML)")
    func thresholds_accept_int_arrays() throws {
        let toml = #"""
        [notifications]
        enabled = true
        notify_at = [70, 90]
        """#
        let cfg = try TOMLDecoder().decode(AppConfig.self, from: toml)
        #expect(cfg.notifications.notifyAt == [70.0, 90.0])
    }

    @Test("KimiConfig fallback when TOML supplies invalid base_url")
    func kimi_config_toml_invalid_base_url_falls_back() throws {
        let toml = #"""
        [kimi]
        enabled = true
        base_url = "http://attacker.example.com/"
        """#
        let cfg = try TOMLDecoder().decode(AppConfig.self, from: toml)
        #expect(cfg.kimi.baseURL == KimiConfig.defaultBaseURL)
    }

    @Test("UpdatesConfig parses owner_repo and include_prereleases")
    func updates_config_parses_fields() throws {
        let toml = #"""
        [updates]
        enabled = false
        owner_repo = "fork/ai-taskbar"
        include_prereleases = true
        """#
        let cfg = try TOMLDecoder().decode(AppConfig.self, from: toml)
        #expect(!cfg.updates.enabled)
        #expect(cfg.updates.ownerRepo == "fork/ai-taskbar")
        #expect(cfg.updates.includePrereleases)
    }

    @Test("flexibleDoubleArray falls back to default when malformed")
    func flexible_double_array_fallback_to_default() throws {
        // notifyAt with non-numeric entries → falls back to default.
        let toml = #"""
        [notifications]
        notify_at = ["never"]
        """#
        let cfg = try TOMLDecoder().decode(AppConfig.self, from: toml)
        #expect(cfg.notifications.notifyAt == [90, 100])
    }

    @Test("SecurityConfig parses pin_hosts and audit_only")
    func security_config_parses_pin_hosts() throws {
        let toml = #"""
        [security]
        pin_hosts = ["api.example.com", "api.other.com"]
        pin_audit_only = true
        """#
        let cfg = try TOMLDecoder().decode(AppConfig.self, from: toml)
        #expect(cfg.security.pinHosts == ["api.example.com", "api.other.com"])
        #expect(cfg.security.pinAuditOnly)
    }
}
