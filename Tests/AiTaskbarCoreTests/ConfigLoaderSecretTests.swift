import Testing
import Foundation
@testable import AiTaskbarCore

/// Integration tests for the `ConfigLoader.applyChanges` surgical write path
/// and its transparent decryption of `enc:v2:` / `enc:v1:` secrets on `load()`.
@Suite("ConfigLoader secret + applyChanges round-trip", .serialized)
struct ConfigLoaderSecretTests {
    static let thisMac = "11111111-2222-3333-4444-555555555555"
    static let otherMac = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    private func makeLoader(in tmp: URL) throws -> ConfigLoader {
        let file = tmp.appendingPathComponent("config.toml")
        var loader = ConfigLoader(path: file)
        loader.machineID = Self.thisMac
        return loader
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
        #expect(cfg.anthropic.enabled)
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

        // On-disk file MUST contain `enc:v2:` and MUST NOT contain the plaintext.
        let onDisk = try String(contentsOf: loader.path, encoding: .utf8)
        #expect(onDisk.contains("enc:v2:"))
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
        #expect(cfg.notifications.enabled)
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

    @Test("save() re-encrypts plaintext api_keys (ARCH-ATL-002)")
    func save_re_encrypts_plaintext_api_keys() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-save-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let loader = try makeLoader(in: tmp)
        var cfg = AppConfig()
        cfg.zai.enabled = true
        cfg.zai.apiKey = "sk-plain-on-save"
        try loader.save(cfg)
        let onDisk = try String(contentsOf: loader.path, encoding: .utf8)
        #expect(onDisk.contains("enc:v2:"))
        #expect(!onDisk.contains("sk-plain-on-save"))
        let loaded = try loader.load()
        #expect(loaded.zai.apiKey == "sk-plain-on-save")
    }

    @Test("ensureAllVendorSections ignores headers only mentioned in comments (BUG-ART-008)")
    func ensure_sections_ignores_comment_headers() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-ens-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent("config.toml")
        try AtomicFileWrite.write(Data("# see [gemini] docs\n[ui]\n".utf8),
                                  to: path, permissions: 0o600)
        let loader = ConfigLoader(path: path)
        let appended = try loader.ensureAllVendorSections()
        #expect(appended.contains("[gemini]"))
        let raw = try String(contentsOf: path, encoding: .utf8)
        #expect(raw.contains("\n[gemini]\n") || raw.contains("\n[gemini]\r"))
    }

    @Test("tampered enc:v1: clears key without failing load (TEST-ARG-003)")
    func tampered_ciphertext_clears_key() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-tamp-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent("config.toml")
        try AtomicFileWrite.write(Data("""
        [zai]
        enabled = true
        api_key = "enc:v1:not-valid-ciphertext=="
        """.utf8), to: path, permissions: 0o600)
        let loader = ConfigLoader(path: path)
        let cfg = try loader.load()
        #expect(cfg.zai.apiKey == nil)
    }

    @Test("applyChanges(.doubleArray) writes unquoted numbers for notify_at (BUG-ART-001)")
    func applyChanges_double_array_notify_at_round_trip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cfg-da-\(UUID().uuidString)")
        try Paths.ensureDir(dir)
        let path = dir.appendingPathComponent("config.toml")
        try AtomicFileWrite.write(Data("""
        [notifications]
        enabled = true
        notify_at = [90, 100]
        """.utf8), to: path, permissions: 0o600)
        let loader = ConfigLoader(path: path)
        try loader.applyChanges([
            .doubleArray(section: "notifications", key: "notify_at", value: [80, 95])
        ])
        let raw = try String(contentsOf: path, encoding: .utf8)
        #expect(raw.contains("notify_at = [80, 95]") || raw.contains("notify_at=[80, 95]"))
        #expect(!raw.contains("\"80\""))
        let cfg = try loader.load()
        #expect(cfg.notifications.notifyAt == [80, 95])
        try? FileManager.default.removeItem(at: dir)
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

    // MARK: Machine-bound enc:v2 + upgrade

    private func seeded(_ body: String) throws -> (ConfigLoader, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-v2-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        let loader = try makeLoader(in: tmp)
        try AtomicFileWrite.write(Data(body.utf8), to: loader.path, permissions: 0o600)
        return (loader, tmp)
    }

    private func backups(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }
    }

    @Test("a secret sealed on this Mac cannot be read on another Mac")
    func v2_unreadable_on_other_mac() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-v2-other-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let loader = try makeLoader(in: tmp)
        try loader.applyChanges([.secret(section: "zai", key: "api_key", plaintext: "sk-bound")])
        #expect(try loader.load().zai.apiKey == "sk-bound")

        var elsewhere = ConfigLoader(path: loader.path)
        elsewhere.machineID = Self.otherMac
        #expect(try elsewhere.load().zai.apiKey == nil)
    }

    @Test("upgrade rewrites plaintext and enc:v1 secrets as enc:v2, after a backup")
    func upgrade_plaintext_and_v1() throws {
        let v1 = try SecretBox.encrypt("sk-or-legacy", machineID: nil)
        #expect(v1.hasPrefix(SecretBox.prefix))
        let (loader, tmp) = try seeded("""
        # keep me
        [zai]
        enabled = true
        api_key = "zai-plain-key"

        [openrouter]
        api_key = "\(v1)"

        [typesafe]
        console_session = "ts-session-plain"
        """)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let original = try Data(contentsOf: loader.path)

        let upgraded = try loader.upgradeSecretsIfNeeded()
        #expect(upgraded == 3)

        let onDisk = try String(contentsOf: loader.path, encoding: .utf8)
        #expect(!onDisk.contains("zai-plain-key"))
        #expect(!onDisk.contains("ts-session-plain"))
        #expect(!onDisk.contains(SecretBox.prefix))
        #expect(onDisk.components(separatedBy: SecretBox.prefixV2).count == 4)
        #expect(onDisk.contains("# keep me"))

        let cfg = try loader.load()
        #expect(cfg.zai.apiKey == "zai-plain-key")
        #expect(cfg.openrouter.apiKey == "sk-or-legacy")
        #expect(cfg.typesafe.consoleSession == "ts-session-plain")

        let made = try backups(in: tmp)
        #expect(made.count == 1)
        let backup = tmp.appendingPathComponent(made[0])
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test("upgrade is a no-op when every secret is already enc:v2")
    func upgrade_noop_when_current() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-v2-noop-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let loader = try makeLoader(in: tmp)
        try loader.applyChanges([.secret(section: "xai", key: "api_key", plaintext: "xai-key")])
        let before = try Data(contentsOf: loader.path)
        #expect(try loader.upgradeSecretsIfNeeded() == 0)
        #expect(try Data(contentsOf: loader.path) == before)
        #expect(try backups(in: tmp).isEmpty)
    }

    @Test("upgrade leaves another Mac's enc:v2 untouched")
    func upgrade_skips_foreign_v2() throws {
        let foreign = try SecretBox.encrypt("sk-foreign", machineID: Self.otherMac)
        let (loader, tmp) = try seeded("[deepseek]\napi_key = \"\(foreign)\"\n")
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(try loader.upgradeSecretsIfNeeded() == 0)
        let onDisk = try String(contentsOf: loader.path, encoding: .utf8)
        #expect(onDisk.contains(foreign))
        #expect(try loader.load().deepseek.apiKey == nil)
    }

    @Test("upgrade does nothing without a machine id or a file")
    func upgrade_without_machine_id_or_file() throws {
        let (seededLoader, tmp) = try seeded("[zai]\napi_key = \"zai-plain\"\n")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var loader = seededLoader
        loader.machineID = nil
        #expect(try loader.upgradeSecretsIfNeeded() == 0)
        #expect(try String(contentsOf: loader.path, encoding: .utf8).contains("zai-plain"))

        let missing = ConfigLoader(path: tmp.appendingPathComponent("absent.toml"))
        #expect(try missing.upgradeSecretsIfNeeded() == 0)
    }

    @Test("upgrade surfaces an unparseable file instead of rewriting it")
    func upgrade_throws_on_bad_toml() throws {
        let (loader, tmp) = try seeded("[zai\napi_key = \"x\"\n")
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(throws: AppError.self) { try loader.upgradeSecretsIfNeeded() }
    }

    @Test("every secret field is sealed by save and unsealed by load")
    func every_secret_field_round_trips() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-v2-all-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let loader = try makeLoader(in: tmp)
        var cfg = AppConfig()
        for (i, field) in ConfigLoader.secretFields.enumerated() {
            cfg[keyPath: field.path] = "secret-\(i)"
        }
        try loader.save(cfg)
        let onDisk = try String(contentsOf: loader.path, encoding: .utf8)
        let loaded = try loader.load()
        for (i, field) in ConfigLoader.secretFields.enumerated() {
            #expect(!onDisk.contains("\"secret-\(i)\""))
            #expect(loaded[keyPath: field.path] == "secret-\(i)")
        }
        #expect(ConfigLoader.secretFields.count == 8)
    }
}
