import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders

@Suite("Provider convenience initializers")
struct ConvenienceInitsTests {
    @Test("ZAIProvider builds from ZAIConfig")
    func zai_convenience_init() throws {
        let cfg = ZAIConfig(
            enabled: true,
            apiKeyEnv: "_UNSET",
            apiKey: "key",
            planTier: "lite")
        let provider = try ZAIProvider(config: cfg, http: .init())
        #expect(provider.vendorId == .zai)
    }

    @Test("OpenRouterProvider builds from OpenRouterConfig")
    func openrouter_convenience_init() throws {
        let cfg = OpenRouterConfig(
            enabled: true,
            apiKeyEnv: "_UNSET",
            apiKey: "key")
        let provider = try OpenRouterProvider(config: cfg, http: .init())
        #expect(provider.vendorId == .openrouter)
    }

    @Test("OpenAIProvider builds with custom codexAuthPath")
    func openai_convenience_with_path() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-conv-\(UUID().uuidString)")
        let provider = try OpenAIProvider(
            http: .init(),
            codexAuthPath: tmp.appendingPathComponent("auth.json"))
        #expect(provider.vendorId == .openai)
    }

    @Test("AnthropicProvider convenience init creates with default service")
    func anthropic_convenience_init() throws {
        // Doesn't touch keychain unless fetchUsage is called.
        let provider = try AnthropicProvider(
            http: .init(),
            keychainService: "ai-taskbar-test-no-such-svc",
            keychainAccount: nil)
        #expect(provider.vendorId == .anthropic)
    }

    @Test("DeepSeekProvider builds from DeepSeekConfig")
    func deepseek_convenience_init() throws {
        let cfg = DeepSeekConfig(
            enabled: true,
            apiKeyEnv: "_UNSET",
            apiKey: "key",
            baseURL: "https://api.deepseek.com")
        let provider = try DeepSeekProvider(config: cfg, http: .init())
        #expect(provider.vendorId == .deepseek)
    }

    @Test("XAIProvider builds from XAIConfig")
    func xai_convenience_init() throws {
        let cfg = XAIConfig(
            enabled: true,
            apiKeyEnv: "_UNSET",
            apiKey: "key",
            teamId: "team-1",
            baseURL: "https://management-api.x.ai")
        let provider = try XAIProvider(config: cfg, http: .init())
        #expect(provider.vendorId == .xai)
    }
}
