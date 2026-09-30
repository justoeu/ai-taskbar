import Foundation
import Testing

@Suite("Keychain authorization localization")
struct KeychainAuthorizationLocalizationTests {
    @Test("authorization denial guidance exists in every supported language")
    func localization_completeness() throws {
        let keys = ["keychain_auth_denied", "keychain_auth_not_persistent"]

        for language in LocalizableStrings.languages {
            let contents = try LocalizableStrings.contents(language)
            for key in keys {
                expectTrue(
                    LocalizableStrings.defines(key, in: contents),
                    "missing \(key) in \(language)"
                )
            }
        }
    }
}
