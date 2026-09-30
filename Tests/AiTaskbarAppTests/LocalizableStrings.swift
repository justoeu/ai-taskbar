import Foundation
import Testing

/// Reads the app's `Localizable.strings` from the source tree, for tests that
/// pin keys and values. One copy of the `#filePath` walk-up the localization
/// tests used to repeat (DUP-MAE-008).
enum LocalizableStrings {
    static let languages = ["en", "pt-BR", "es"]

    /// The repository root: this file lives in `Tests/AiTaskbarAppTests/`.
    static var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    static func url(_ language: String) -> URL {
        repositoryRoot
            .appendingPathComponent("Sources/AiTaskbarApp/Resources")
            .appendingPathComponent("\(language).lproj/Localizable.strings")
    }

    static func contents(_ language: String) throws -> String {
        try String(contentsOf: url(language), encoding: .utf8)
    }

    /// Whether `contents` defines `key` (`"key" = …`).
    static func defines(_ key: String, in contents: String) -> Bool {
        contents.contains("\"\(key)\" = ")
    }
}

@Suite("LocalizableStrings test helper")
struct LocalizableStringsHelperTests {
    @Test("finds a real key in every language and rejects a missing one")
    func positive_and_negative_control() throws {
        for language in LocalizableStrings.languages {
            let contents = try LocalizableStrings.contents(language)
            #expect(LocalizableStrings.defines("done", in: contents), "\(language)")
            #expect(!LocalizableStrings.defines("__no_such_key__", in: contents), "\(language)")
        }
    }
}
