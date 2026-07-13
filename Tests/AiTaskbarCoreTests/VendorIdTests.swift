import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("VendorId enum surface")
struct VendorIdTests {
    @Test("displayName covers every case")
    func displayName_covers_every_case() {
        // Pin each label so a rename forces a deliberate test update.
        #expect(VendorId.anthropic.displayName == "Claude")
        #expect(VendorId.openai.displayName == "Codex / ChatGPT")
        #expect(VendorId.zai.displayName == "Z.AI (GLM)")
        #expect(VendorId.openrouter.displayName == "OpenRouter")
        #expect(VendorId.kimi.displayName == "Kimi (Moonshot)")
        #expect(VendorId.gemini.displayName == "Gemini (Google AI)")
        #expect(VendorId.deepseek.displayName == "DeepSeek")
        #expect(VendorId.xai.displayName == "xAI (Grok)")
    }

    @Test("dashboardURL is non-nil and uses https for every vendor")
    func dashboardURL_is_https_for_every_vendor() {
        for v in VendorId.allCases {
            let url = v.dashboardURL
            #expect(url != nil, "\(v) missing dashboard URL")
            #expect(url?.scheme == "https", "\(v) dashboard isn't https")
        }
    }

    @Test("OAuth vendors expose their CLI re-login commands")
    func oauth_vendors_expose_relogin_commands() {
        #expect(VendorId.anthropic.reloginCommand == "claude auth login")
        #expect(VendorId.openai.reloginCommand == "codex login")
    }

    @Test("API-key vendors do not expose a misleading re-login command")
    func api_key_vendors_have_no_relogin_command() {
        #expect(VendorId.zai.reloginCommand == nil)
        #expect(VendorId.openrouter.reloginCommand == nil)
        #expect(VendorId.kimi.reloginCommand == nil)
        #expect(VendorId.gemini.reloginCommand == nil)
        #expect(VendorId.deepseek.reloginCommand == nil)
        #expect(VendorId.xai.reloginCommand == nil)
    }

    @Test("id mirrors rawValue (Identifiable)")
    func id_mirrors_rawValue() {
        for v in VendorId.allCases {
            #expect(v.id == v.rawValue)
        }
    }

    @Test("CaseIterable enumerates all eight vendors")
    func caseIterable_enumerates_all() {
        #expect(VendorId.allCases.count == 8)
    }

    @Test("Codable round-trip preserves rawValue")
    func codable_round_trip() throws {
        for v in VendorId.allCases {
            let data = try JSONEncoder().encode(v)
            let back = try JSONDecoder().decode(VendorId.self, from: data)
            #expect(back == v)
        }
    }
}
