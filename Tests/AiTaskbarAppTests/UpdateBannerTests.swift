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

    private static var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    @Test("the empty-release-list message is localized in every supported language")
    func no_release_key_exists() throws {
        for language in ["en", "pt-BR", "es"] {
            let file = Self.repositoryRoot
                .appendingPathComponent("Sources/AiTaskbarApp/Resources/\(language).lproj/Localizable.strings")
            let contents = try String(contentsOf: file, encoding: .utf8)
            expectTrue(contents.contains("\"updates_no_release\" = "), "missing in \(language)")
        }
    }

    /// ARCH-ATL-004: the composition root must hand UpdateChecker the
    /// environment's client (pinned when `pin_hosts` is set), not a fresh one.
    @Test("the app wires UpdateChecker to env.http")
    func composition_root_injects_environment_http() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Sources/AiTaskbarApp/AiTaskbarApp.swift"),
            encoding: .utf8)
        let call = try #require(source.range(of: "UpdateChecker("))
        let close = try #require(source[call.upperBound...].firstIndex(of: ")"))
        let arguments = String(source[call.upperBound..<close])
        expectTrue(arguments.contains("http: env.http"), "UpdateChecker(\(arguments))")
    }
}
