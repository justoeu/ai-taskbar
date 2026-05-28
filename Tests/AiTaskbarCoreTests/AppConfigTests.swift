import XCTest
import TOMLKit
@testable import AiTaskbarCore

final class AppConfigTests: XCTestCase {
    func test_missing_sections_fall_back_to_defaults() throws {
        let toml = #"""
        [ui]
        primary = "openai"
        """#
        let cfg = try TOMLDecoder().decode(AppConfig.self, from: toml)
        XCTAssertEqual(cfg.ui.primary, .openai)
        XCTAssertTrue(cfg.anthropic.enabled)
        XCTAssertEqual(cfg.zai.apiKeyEnv, "ZAI_API_KEY")
    }

    func test_full_round_trip() throws {
        let toml = #"""
        [ui]
        primary = "zai"

        [anthropic]
        enabled = false

        [openai]
        enabled = true
        codex_auth_path = "/tmp/auth.json"

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
        XCTAssertEqual(cfg.ui.primary, .zai)
        XCTAssertFalse(cfg.anthropic.enabled)
        XCTAssertEqual(cfg.openai.codexAuthPath, "/tmp/auth.json")
        XCTAssertEqual(cfg.zai.apiKey, "abc")
        XCTAssertEqual(cfg.zai.planTier, "pro")
        XCTAssertFalse(cfg.openrouter.enabled)
    }
}
