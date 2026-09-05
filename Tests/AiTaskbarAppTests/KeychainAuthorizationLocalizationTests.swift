import Foundation
import Testing
import AiTaskbarTestSupport

@Suite("Keychain authorization localization")
struct KeychainAuthorizationLocalizationTests {
    @Test("password rejection guidance exists in every supported language")
    func localization_completeness() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { repositoryRoot.deleteLastPathComponent() }
        let resources = repositoryRoot
            .appendingPathComponent("Sources/AiTaskbarApp/Resources")
        let keys = ["keychain_auth_password_rejected"]

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
