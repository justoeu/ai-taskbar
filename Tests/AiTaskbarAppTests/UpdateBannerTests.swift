import Foundation
import Testing
import AiTaskbarCore
@testable import AiTaskbarApp

@Suite("Update Banner Presentation and Localization Tests")
struct UpdateBannerTests {
    @Test("Update banner localization keys exist in every supported language")
    func localization_keys_exist() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { repositoryRoot.deleteLastPathComponent() }
        let resources = repositoryRoot
            .appendingPathComponent("Sources/AiTaskbarApp/Resources")
        let keys = [
            "update_banner_available_fmt",
            "update_banner_button",
            "update_banner_downloading",
            "update_banner_ready",
            "update_banner_open",
            "update_banner_dismiss"
        ]

        for language in ["en", "pt-BR", "es"] {
            let file = resources
                .appendingPathComponent("\(language).lproj")
                .appendingPathComponent("Localizable.strings")
            let contents = try String(contentsOf: file, encoding: .utf8)
            for key in keys {
                expectTrue(
                    contents.contains("\"\(key)\" = "),
                    "missing \(key) in \(language)"
                )
            }
        }
    }
}
