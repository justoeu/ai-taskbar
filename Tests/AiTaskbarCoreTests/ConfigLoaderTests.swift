import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("ConfigLoader load + save + ensureAllVendorSections")
struct ConfigLoaderTests {
    let tmp: URL

    init() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cfgloader-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
    }

    private func tempConfigPath() -> URL {
        tmp.appendingPathComponent("config.toml")
    }

    @Test("init() with no args resolves the default support-dir path")
    func init_default_path() throws {
        let loader = try ConfigLoader()
        #expect(loader.path.lastPathComponent == "config.toml")
    }

    @Test("load returns defaults when file does not exist")
    func load_returns_defaults_when_missing() throws {
        let loader = ConfigLoader(path: tempConfigPath())
        let cfg = try loader.load()
        #expect(cfg.anthropic.enabled)
        #expect(cfg.ui.refreshIntervalSeconds == 150)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("save writes the file with 0o600 perms")
    func save_writes_file_with_0o600() throws {
        let path = tempConfigPath()
        let loader = ConfigLoader(path: path)
        try loader.save(AppConfig())
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("load surfaces TOML parse error as AppError.toml")
    func load_surfaces_toml_parse_error() throws {
        let path = tempConfigPath()
        try "not = valid = toml = at all".write(to: path, atomically: true, encoding: .utf8)
        let loader = ConfigLoader(path: path)
        do {
            _ = try loader.load()
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .toml = err {} else {
                Issue.record("expected .toml, got \(err)")
            }
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("ensureAllVendorSections is idempotent — no-op when file is empty")
    func ensure_idempotent_no_file() throws {
        let loader = ConfigLoader(path: tempConfigPath())
        // No file → returns empty list, doesn't crash.
        let appended = try loader.ensureAllVendorSections()
        #expect(appended.isEmpty)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("ensureAllVendorSections appends missing sections to existing file")
    func ensure_appends_missing_sections() throws {
        let path = tempConfigPath()
        try "[anthropic]\nenabled = true\n".write(to: path, atomically: true, encoding: .utf8)
        let loader = ConfigLoader(path: path)
        let appended = try loader.ensureAllVendorSections()
        #expect(appended.contains("[ui]"))
        #expect(appended.contains("[openai]"))
        #expect(!appended.contains("[anthropic]"), "existing section must not be re-appended")
        let updated = try String(contentsOf: path, encoding: .utf8)
        #expect(updated.contains("[ui]"))
        #expect(updated.contains("[openai]"))
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("save + load round-trip preserves vendor flags")
    func save_load_round_trip() throws {
        let path = tempConfigPath()
        var cfg = AppConfig()
        cfg.anthropic.enabled = false
        cfg.zai.apiKey = "abc"
        let loader = ConfigLoader(path: path)
        try loader.save(cfg)
        let back = try loader.load()
        #expect(!back.anthropic.enabled)
        #expect(back.zai.apiKey == "abc")
        try? FileManager.default.removeItem(at: tmp)
    }
}

@Suite("KimiConfig URL allowlist validation")
struct KimiConfigTests {
    @Test("default base URL accepted")
    func default_base_url_accepted() {
        let c = KimiConfig(baseURL: "https://api.moonshot.ai/v1")
        #expect(c.baseURL == "https://api.moonshot.ai/v1")
    }

    @Test("China region URL accepted")
    func china_url_accepted() {
        let c = KimiConfig(baseURL: "https://api.moonshot.cn/v1")
        #expect(c.baseURL == "https://api.moonshot.cn/v1")
    }

    @Test("http (non-TLS) rejected, falls back to default")
    func http_rejected() {
        let c = KimiConfig(baseURL: "http://api.moonshot.ai/v1")
        #expect(c.baseURL == KimiConfig.defaultBaseURL)
    }

    @Test("attacker-controlled host rejected")
    func unauthorized_host_rejected() {
        let c = KimiConfig(baseURL: "https://evil.example.com/v1")
        #expect(c.baseURL == KimiConfig.defaultBaseURL)
    }

    @Test("subdomain of allowed host NOT allowed")
    func subdomain_not_auto_allowed() {
        let c = KimiConfig(baseURL: "https://staging.api.moonshot.ai/v1")
        #expect(c.baseURL == KimiConfig.defaultBaseURL)
    }
}
