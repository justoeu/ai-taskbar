import Testing
import Foundation
@testable import AiTaskbarCore

/// Tests for the surgical TOML editor. The headline invariant: comments,
/// blank lines, unknown keys, and ordering MUST survive every edit.
@Suite("TOMLEditor — comment-preserving surgical edit")
struct TOMLEditorTests {
    private let fixture = """
    # This is a hand-written config with comments the user cares about.

    [ui]
    # primary = "anthropic"             # which tab opens first
    refresh_interval_seconds = 300      # default 300 (5m). Floor 15.
    # language = "pt-BR"                # force UI language

    [thresholds]
    warning  = 70
    critical = 90

    [anthropic]
    enabled = true
    # keychain_account = "your.short.username"
    manage_oauth_refresh = false

    [openrouter]
    enabled     = true
    api_key_env = "OPENROUTER_API_KEY"
    api_key     = "sk-or-plaintext"     # user note about which key
    custom_unknown_field = "preserved"  # not in schema, must survive
    """

    @Test("replaces string value in place, preserving comment")
    func replace_string_preserves_comment() throws {
        let out = try TOMLEditor.setValue(
            in: fixture, section: "openrouter", key: "api_key",
            value: .string("sk-or-new-value"))
        #expect(out.contains("api_key     = \"sk-or-new-value\""))
        // Inline comment after the value is preserved.
        #expect(out.contains("# user note about which key"))
        // Other sections untouched.
        #expect(out.contains("refresh_interval_seconds = 300"))
        #expect(out.contains("warning  = 70"))
    }

    @Test("replaces double value (integer form when whole)")
    func replace_double_integer_form() throws {
        let out = try TOMLEditor.setValue(
            in: fixture, section: "thresholds", key: "warning",
            value: .double(80))
        // Original line used 2-space alignment (`warning  = 70`); the editor
        // preserves user whitespace, so we look for the value with the
        // original spacing.
        #expect(out.contains("warning  = 80") || out.contains("warning = 80"))
        #expect(!out.contains("80.0"))
    }

    @Test("replaces double value (decimal form when fractional)")
    func replace_double_decimal_form() throws {
        let out = try TOMLEditor.setValue(
            in: fixture, section: "thresholds", key: "warning",
            value: .double(82.5))
        #expect(out.contains("warning  = 82.5") || out.contains("warning = 82.5"))
    }

    @Test("replaces bool value")
    func replace_bool() throws {
        let out = try TOMLEditor.setValue(
            in: fixture, section: "anthropic", key: "manage_oauth_refresh",
            value: .bool(true))
        #expect(out.contains("manage_oauth_refresh = true"))
    }

    @Test("replaces string-array value")
    func replace_string_array() throws {
        let out = try TOMLEditor.setValue(
            in: fixture, section: "security", key: "pin_hosts",
            value: .stringArray(["api.anthropic.com", "chatgpt.com"]))
        #expect(out.contains("pin_hosts = [\"api.anthropic.com\", \"chatgpt.com\"]"))
    }

    @Test("encrypted value renders as quoted string")
    func encrypted_renders_as_string() throws {
        let out = try TOMLEditor.setValue(
            in: fixture, section: "zai", key: "api_key",
            value: .encrypted("enc:v1:AAABBBCCC=="))
        #expect(out.contains("api_key = \"enc:v1:AAABBBCCC==\""))
    }

    @Test("adds new key to existing section (inserted before next header)")
    func add_key_to_existing_section() throws {
        let out = try TOMLEditor.setValue(
            in: fixture, section: "ui", key: "language",
            value: .string("pt-BR"))
        // New line present.
        #expect(out.contains("language = \"pt-BR\""))
        // The line lands inside [ui], before [thresholds].
        let ui = out.range(of: "[ui]")
        let thresh = out.range(of: "[thresholds]")
        let lang = out.range(of: "language = \"pt-BR\"")
        #expect(ui != nil && thresh != nil && lang != nil)
        #expect(ui!.lowerBound < lang!.lowerBound)
        #expect(lang!.lowerBound < thresh!.lowerBound)
    }

    @Test("creates missing section at end of file")
    func creates_missing_section() throws {
        let out = try TOMLEditor.setValue(
            in: fixture, section: "gemini", key: "enabled",
            value: .bool(true))
        #expect(out.contains("[gemini]"))
        #expect(out.contains("enabled = true"))
        // Existing content preserved.
        #expect(out.contains("refresh_interval_seconds = 300"))
    }

    @Test("comments and blank lines all preserved on edit")
    func comments_and_blanks_preserved() throws {
        let out = try TOMLEditor.setValue(
            in: fixture, section: "anthropic", key: "enabled",
            value: .bool(false))
        // Top-of-file comment
        #expect(out.contains("# This is a hand-written config with comments the user cares about."))
        // Inline comments
        #expect(out.contains("# primary = \"anthropic\""))
        #expect(out.contains("# keychain_account = \"your.short.username\""))
        // Unknown field (not in schema) still there
        #expect(out.contains("custom_unknown_field = \"preserved\""))
    }

    @Test("original ordering of sections preserved")
    func section_order_preserved() throws {
        let out = try TOMLEditor.setValue(
            in: fixture, section: "anthropic", key: "enabled",
            value: .bool(false))
        let sections = ["[ui]", "[thresholds]", "[anthropic]", "[openrouter]"]
        var lastIdx = out.startIndex
        for s in sections {
            let r = out.range(of: s)
            #expect(r != nil, "missing \(s)")
            #expect(r!.lowerBound > lastIdx, "\(s) out of order")
            lastIdx = r!.lowerBound
        }
    }

    @Test("strings with special characters are properly escaped")
    func string_escaping() throws {
        let out = try TOMLEditor.setValue(
            in: fixture, section: "openrouter", key: "api_key",
            value: .string("path\\with\\backslash \"quoted\""))
        #expect(out.contains("\"path\\\\with\\\\backslash \\\"quoted\\\"\""))
    }

    @Test("parseSectionHeader recognizes [section] but not [[array]]")
    func parse_section_header() {
        #expect(TOMLEditor.parseSectionHeader("[ui]") == "ui")
        #expect(TOMLEditor.parseSectionHeader("[anthropic]") == "anthropic")
        #expect(TOMLEditor.parseSectionHeader("  [ui]  ") == "ui")
        #expect(TOMLEditor.parseSectionHeader("[[array]]") == nil)
        #expect(TOMLEditor.parseSectionHeader("not a header") == nil)
        #expect(TOMLEditor.parseSectionHeader("[]") == nil)
    }

    @Test("parseKeyLine recognizes bare and quoted keys")
    func parse_key_line() {
        #expect(TOMLEditor.parseKeyLine("enabled = true") == "enabled")
        #expect(TOMLEditor.parseKeyLine("  refresh_interval_seconds  =  300") == "refresh_interval_seconds")
        #expect(TOMLEditor.parseKeyLine("\"quoted_key\" = 1") == "quoted_key")
        #expect(TOMLEditor.parseKeyLine("# comment") == nil)
        #expect(TOMLEditor.parseKeyLine("dotted.key = 1") == nil)
        #expect(TOMLEditor.parseKeyLine("[section]") == nil)
    }

    @Test("empty file becomes a single section")
    func empty_file_creates_section() throws {
        let out = try TOMLEditor.setValue(
            in: "", section: "ui", key: "language",
            value: .string("en"))
        #expect(out.contains("[ui]"))
        #expect(out.contains("language = \"en\""))
    }
}
