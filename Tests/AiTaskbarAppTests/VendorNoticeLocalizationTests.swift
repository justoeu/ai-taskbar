import Foundation
import Testing
import AiTaskbarCore
@testable import AiTaskbarApp

/// CQ-AUR-001 / ARCH-ATL-001: Gemini and xAI notices are structure in the
/// snapshot/error and are rendered here in the user's language. Before the
/// fix they were Portuguese sentences shown verbatim to en/es users.
@MainActor
@Suite("Vendor notice localization", .serialized)
struct VendorNoticeLocalizationTests {
    private static func strings(_ language: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let file = root
            .appendingPathComponent("Sources/AiTaskbarApp/Resources")
            .appendingPathComponent("\(language).lproj/Localizable.strings")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private static var allKeys: [String] {
        VendorDisclaimer.allCases.map { VendorNoticeText.key(for: $0) }
            + VendorGuidance.allCases.map { VendorNoticeText.key(for: $0) }
    }

    @Test("every notice key exists in en, pt-BR and es")
    func keys_exist_in_every_language() throws {
        for language in ["en", "pt-BR", "es"] {
            let contents = try Self.strings(language)
            for key in Self.allKeys {
                expectTrue(contents.contains("\"\(key)\" = "), "missing \(key) in \(language)")
            }
        }
    }

    @Test("notice keys are distinct")
    func keys_are_distinct() {
        #expect(Set(Self.allKeys).count == Self.allKeys.count)
    }

    @Test("Gemini disclaimer renders in English under languageOverride=en")
    func gemini_disclaimer_english() {
        let prev = L10n.languageOverride
        defer { L10n.languageOverride = prev }
        L10n.languageOverride = "en"
        #expect(VendorNoticeText.text(for: .antigravityRequired)
                == "To monitor Gemini quotas, Antigravity must be installed and authenticated.")
    }

    @Test("Grok disclaimer renders in Spanish under languageOverride=es")
    func grok_disclaimer_spanish() {
        let prev = L10n.languageOverride
        defer { L10n.languageOverride = prev }
        L10n.languageOverride = "es"
        #expect(VendorNoticeText.text(for: .grokCLIRequired)
                == "Para monitorear Grok, es necesario tener Grok instalado y autenticado.")
    }

    @Test("guidance error renders the localized sentence, not the diagnostic")
    func guidance_error_is_localized() {
        let prev = L10n.languageOverride
        defer { L10n.languageOverride = prev }
        L10n.languageOverride = "en"
        #expect(VendorNoticeText.message(for: .guidance(.antigravityNotFound))
                == "Antigravity not found — install and authenticate Antigravity (`agy`) to monitor Gemini.")
    }

    @Test("every guidance case resolves to a translation in every language")
    func guidance_resolves_everywhere() {
        let prev = L10n.languageOverride
        defer { L10n.languageOverride = prev }
        for language in ["en", "pt-BR", "es"] {
            L10n.languageOverride = language
            for g in VendorGuidance.allCases {
                let key = VendorNoticeText.key(for: g)
                #expect(VendorNoticeText.message(for: .guidance(g)) != key, "\(language): \(key)")
            }
        }
    }

    @Test("non-guidance errors keep their own description")
    func other_errors_pass_through() {
        #expect(VendorNoticeText.message(for: .io("agy: quota exceeded")) == "io: agy: quota exceeded")
    }
}
