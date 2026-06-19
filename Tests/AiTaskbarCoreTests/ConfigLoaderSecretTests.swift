import Testing
import Foundation
@testable import AiTaskbarCore

/// Integration tests for the `ConfigLoader.applyChanges` surgical write path
/// and its transparent decryption of `enc:v1:`-prefixed secrets on `load()`.
@Suite("ConfigLoader secret + applyChanges round-trip", .serialized)
struct ConfigLoaderSecretTests {
    private func makeLoader(in tmp: URL) throws -> ConfigLoader {
        let file = tmp.appendingPathComponent("config.toml")
        return ConfigLoader(path: file)
    }

    @Test("applyChanges writes a normal field and re-load reads it back")
    func applyChanges_normal_field_round_trip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cfg-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loader = try makeLoader(in: tmp)
        // Seed with a baseline file so TOMLEditor has something to edit.
        try loader.applyChanges([
            .bool(section: "anthropic", key: "enabled", value: true),
            .double(section: "thresholds", key: "warning", value: 75),
        ])
        let cfg = try loader.load()
        #expect(cfg.anthropic.enabled == true)
        #expect(cfg.thresholds.warning == 75)
    }

    @Test("HEADLINE: applyChanges(.secret) encrypts on disk and decrypts on load")
    func secret_round_trip_encrypt_decrypt() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-sec-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loader = try makeLoader(in: tmp)
        let plaintext = "sk-zai-secret-12345"
        try loader.applyChanges([
            .bool(section: "zai", key: "enabled", value: true),
            .string(section: "zai", key: "api_key_env", value: "ZAI_API_KEY"),
            .secret(section: "zai", key: "api_key", plaintext: plaintext),
        ])

        // On-disk file MUST contain `enc:v1:` and MUST NOT contain the plaintext.
        let onDisk = try String(contentsOf: loader.path, encoding: .utf8)
        #expect(onDisk.contains("enc:v1:"))
        #expect(!onDisk.contains(plaintext))

        // Loaded config decrypts transparently.
        let cfg = try loader.load()
        #expect(cfg.zai.apiKey == plaintext)
    }

    @Test("applyChanges(.secret nil) clears the slot")
    func secret_clear() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-clr-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loader = try makeLoader(in: tmp)
        try loader.applyChanges([
            .secret(section: "kimi", key: "api_key", plaintext: "set-once"),
        ])
        try loader.applyChanges([
            .secret(section: "kimi", key: "api_key", plaintext: nil),
        ])
        let cfg = try loader.load()
        #expect(cfg.kimi.apiKey == nil || cfg.kimi.apiKey == "")
    }

    @Test("plaintext api_key from legacy file still loads (backward compat)")
    func plaintext_legacy_loads() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-leg-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loader = try makeLoader(in: tmp)
        // Hand-write a legacy plaintext file BEFORE load.
        let legacy = """
        [openrouter]
        api_key = "sk-or-legacy-plaintext"
        """
        try legacy.write(to: loader.path, atomically: true, encoding: .utf8)

        let cfg = try loader.load()
        #expect(cfg.openrouter.apiKey == "sk-or-legacy-plaintext")
    }

    @Test("multiple changes in one batch apply atomically")
    func batch_apply() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-batch-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loader = try makeLoader(in: tmp)
        try loader.applyChanges([
            .string(section: "ui", key: "primary", value: "anthropic"),
            .double(section: "ui", key: "refresh_interval_seconds", value: 600),
            .double(section: "thresholds", key: "warning", value: 80),
            .double(section: "thresholds", key: "critical", value: 95),
            .bool(section: "notifications", key: "enabled", value: true),
        ])
        let cfg = try loader.load()
        #expect(cfg.ui.refreshIntervalSeconds == 600)
        #expect(cfg.thresholds.warning == 80)
        #expect(cfg.thresholds.critical == 95)
        #expect(cfg.notifications.enabled == true)
    }

    @Test("onAfterSave hook fires exactly once per applyChanges call")
    func on_after_save_hook_fires() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-hook-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var loader = try makeLoader(in: tmp)
        // Swift 6 strict-concurrency: a class-wrapped counter keeps the
        // Sendable closure sound without nonisolated(unsafe) globals.
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        loader.onAfterSave = { [counter] in counter.value += 1 }
        try loader.applyChanges([
            .bool(section: "anthropic", key: "enabled", value: true),
        ])
        #expect(counter.value == 1)
        // save() also fires the hook.
        try loader.save(AppConfig())
        #expect(counter.value == 2)
    }

    @Test("permissions are 0o600 after applyChanges (audit compliance)")
    func permissions_0o600() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-perm-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loader = try makeLoader(in: tmp)
        try loader.applyChanges([
            .secret(section: "zai", key: "api_key", plaintext: "x"),
        ])
        let attrs = try FileManager.default.attributesOfItem(atPath: loader.path.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600, "config.toml must be 0o600 because it can hold encrypted api_keys")
    }
}
