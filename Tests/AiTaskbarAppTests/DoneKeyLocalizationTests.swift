import Foundation
import Testing

/// BUG-MAE-016: `"done"` was defined twice in every Localizable.strings, and
/// the two pt-BR entries disagreed ("Concluir" vs "Concluído"), so which
/// word the Settings save-failure alert showed depended on the parser keeping
/// the last duplicate. The key now has exactly one definition per language;
/// pt-BR uses "Concluído", the macOS convention for a button that dismisses.
@Suite("\"done\" key localization")
struct DoneKeyLocalizationTests {
    private static func values(of key: String, in language: String) throws -> [String] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let file = root
            .appendingPathComponent("Sources/AiTaskbarApp/Resources")
            .appendingPathComponent("\(language).lproj/Localizable.strings")
        let prefix = "\"\(key)\" = \""
        return try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(prefix) }
            .map { line in
                let rest = line.dropFirst(prefix.count)
                return String(rest.prefix { $0 != "\"" })
            }
    }

    @Test("\"done\" is defined once per language", arguments: ["en", "pt-BR", "es"])
    func done_defined_once(language: String) throws {
        #expect(try Self.values(of: "done", in: language).count == 1)
    }

    @Test("pt-BR \"done\" reads Concluído")
    func done_pt_br_value() throws {
        #expect(try Self.values(of: "done", in: "pt-BR") == ["Concluído"])
    }
}
