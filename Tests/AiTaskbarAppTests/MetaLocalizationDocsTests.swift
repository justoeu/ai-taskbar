import Testing
import Foundation

/// Pins for T-011 (Meta strings) and T-012 (Meta docs), added after the
/// round-1 correctness review found both tasks claimed tests that did not
/// exist. Reversal-verified: both fail with the strings/docs changes
/// stashed and pass with them present.
@Suite("Meta localization + docs pins (T-011/T-012)")
struct MetaLocalizationDocsTests {
    static let metaKeys = [
        "meta_payg", "meta_billing_incomplete", "meta_quota_unavailable",
        "settings_meta_footer", "settings_meta_login",
        "settings_meta_login_detected", "settings_meta_login_missing",
        "settings_meta_sessions_dir", "settings_meta_sessions_dir_help",
        "settings_meta_auth_path", "settings_meta_auth_path_help",
        "settings_meta_login_blocked", "settings_meta_sessions",
        "settings_meta_sessions_found", "settings_meta_sessions_missing",
        "guidance_meta_login_required", "guidance_meta_keychain_blocked",
        "settings_meta_login_unavailable",
    ]

    @Test("every Meta key is defined in en, pt-BR and es")
    func meta_keys_everywhere() throws {
        for language in LocalizableStrings.languages {
            let contents = try LocalizableStrings.contents(language)
            for key in Self.metaKeys {
                #expect(LocalizableStrings.defines(key, in: contents),
                        "\(language) missing \(key)")
            }
        }
    }

    @Test("README and AGENTS document the Meta vendor and scanner semantics")
    func docs_present() throws {
        let root = LocalizableStrings.repositoryRoot
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"),
                                encoding: .utf8)
        #expect(readme.contains("| **Muse (Meta)** |"))
        #expect(readme.contains("### Meta (Muse)"))
        #expect(readme.contains("[meta]\nenabled = false"))
        let agents = try String(contentsOf: root.appendingPathComponent("AGENTS.md"),
                                encoding: .utf8)
        #expect(agents.contains("`MuseSessionScanner` (`~/.local/share/muse/sessions`)"))
        #expect(agents.contains("docs/SDD-meta-muse.md"))
    }
}
