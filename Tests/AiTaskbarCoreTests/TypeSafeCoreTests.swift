import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("TypeSafe config, vendor id and snapshot")
struct TypeSafeCoreTests {
    // MARK: VendorId

    @Test("vendor id metadata")
    func vendor_id() {
        #expect(VendorId.typesafe.rawValue == "typesafe")
        #expect(VendorId.typesafe.displayName == "Jev (TypeSafe)")
        #expect(VendorId.typesafe.dashboardURL?.absoluteString == "https://console.typesafe.ai/usage")
        #expect(VendorId.typesafe.statusPageURL?.absoluteString == "https://status.typesafe.ai")
        #expect(VendorId.typesafe.isPrepaidOnly)
        expectTrue(VendorId.typesafe.reloginCommand == nil)
    }

    @Test("only TypeSafe reports no utilization")
    func reports_utilization() {
        #expect(!VendorId.typesafe.reportsUtilization)
        for v in VendorId.allCases where v != .typesafe {
            #expect(v.reportsUtilization, "\(v)")
        }
    }

    // MARK: TypeSafeConfig

    @Test("disabled by default, structurally")
    func disabled_by_default() throws {
        #expect(!TypeSafeConfig().enabled)
        #expect(!AppConfig().typesafe.enabled)
        // A [typesafe] table without `enabled` stays disabled.
        let decoded = try JSONDecoder().decode(TypeSafeConfig.self, from: Data(#"{"api_key_env":"X"}"#.utf8))
        #expect(!decoded.enabled)
        #expect(decoded.apiKeyEnv == "X")
    }

    @Test("base_url accepts only the official host", arguments: [
        ("https://api.typesafe.ai", true),
        ("https://api.typesafe.ai/", true),
        ("https://API.typesafe.ai", true),
        ("http://api.typesafe.ai", false),
        ("https://evil.example.com", false),
        ("https://api.typesafe.ai.evil.com", false),
        ("https://x.api.typesafe.ai", false),
        ("https://user:pw@api.typesafe.ai", false),
        ("https://api.typesafe.ai:8443", false),
        ("https://api.typesafe.ai:443", true),
        ("https://api.typesafe.ai/v1", false),
        ("https://api.typesafe.ai/?x=1", false),
        ("not a url", false),
    ])
    func base_url_validation(_ raw: String, _ accepted: Bool) {
        let accept = TypeSafeConfig.validate(raw) != nil
        #expect(accept == accepted, "\(raw)")
        let c = TypeSafeConfig(baseURL: raw)
        #expect(c.baseURL == (accepted ? raw : TypeSafeConfig.defaultBaseURL))
    }

    @Test("a rejected base_url in the file falls back to the default")
    func decode_rejects_bad_url() throws {
        let c = try JSONDecoder().decode(TypeSafeConfig.self,
                                         from: Data(#"{"enabled":true,"base_url":"https://evil.example.com"}"#.utf8))
        #expect(c.baseURL == TypeSafeConfig.defaultBaseURL)
        #expect(c.enabled)
    }

    // MARK: ConfigLoader

    @Test("the default [typesafe] snippet is appended disabled")
    func snippet_disabled() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-ts-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = tmp.appendingPathComponent("config.toml")
        try AtomicFileWrite.write(Data("[ui]\n".utf8), to: path, permissions: 0o600)
        let loader = ConfigLoader(path: path)
        let appended = try loader.ensureAllVendorSections()
        #expect(appended.contains("[typesafe]"))
        let cfg = try loader.load()
        #expect(!cfg.typesafe.enabled)
        #expect(cfg.typesafe.apiKeyEnv == "TYPESAFE_API_KEY")
        #expect(cfg.typesafe.baseURL == TypeSafeConfig.defaultBaseURL)
    }

    @Test("an inline TypeSafe key is encrypted on disk and decrypted on load")
    func key_sealed_on_disk() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-ts-seal-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var loader = ConfigLoader(path: tmp.appendingPathComponent("config.toml"))
        loader.machineID = "11111111-2222-3333-4444-555555555555"
        var cfg = AppConfig()
        cfg.typesafe.enabled = true
        cfg.typesafe.apiKey = "ts-plain-on-save"
        try loader.save(cfg)
        let onDisk = try String(contentsOf: loader.path, encoding: .utf8)
        #expect(onDisk.contains("enc:v2:"))
        #expect(!onDisk.contains("ts-plain-on-save"))
        #expect(try loader.load().typesafe.apiKey == "ts-plain-on-save")
    }

    // MARK: Snapshot

    @Test("snapshot round-trips, and an older cache without billing decodes")
    func snapshot_codable() throws {
        let credit = TypeSafeCredit(amountUSD: 30, remainingUSD: 30,
                                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                                    reason: "purchased_credits")
        let s = TypeSafeSnapshot(models: [TypeSafeModel(name: "jev-latest")],
                                 billing: TypeSafeBilling(spentUSD: 0, balanceUSD: 30, plan: "pay_as_you_go",
                                                          cycleLabel: "September 2026", cycleEndsInDays: 2,
                                                          credits: [credit]))
        let snap = VendorSnapshot.typesafe(s)
        let round = try JSONDecoder().decode(VendorSnapshot.self, from: JSONEncoder().encode(snap))
        #expect(round == snap)

        let legacy = try JSONDecoder().decode(TypeSafeSnapshot.self, from: Data(#"{"models":[{"name":"jev-latest"}]}"#.utf8))
        expectTrue(legacy.billing == nil)
        #expect(legacy.modelCount == 1)
        let empty = try JSONDecoder().decode(TypeSafeSnapshot.self, from: Data("{}".utf8))
        #expect(empty.models.isEmpty)
        expectTrue(empty.lastUpdated == nil)
    }
}
