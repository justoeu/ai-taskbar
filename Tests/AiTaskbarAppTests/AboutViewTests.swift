import Foundation
import SwiftUI
import Testing
@testable import AiTaskbarApp
import AiTaskbarCore

@MainActor
@Suite("AboutView")
struct AboutViewTests {
    @Test("AboutView callbacks trigger correctly")
    func callbacks_trigger() {
        var doneCalled = false
        var quitCalled = false

        let view = AboutView(
            onDone: { doneCalled = true },
            onQuit: { quitCalled = true }
        )

        view.onDone()
        #expect(doneCalled)

        view.onQuit()
        #expect(quitCalled)
    }

    @Test("Quit confirmation localization keys exist across all supported languages")
    func localization_keys() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }

        let keys = [
            "quit_app",
            "quit_confirm_title",
            "quit_confirm_message",
            "quit_confirm_button",
            "cancel",
            "back",
            "about_description"
        ] + AboutView.facts.map(\.key) + AboutView.facts.compactMap(\.helpKey)

        for language in ["en", "pt-BR", "es"] {
            let file = root.appendingPathComponent("Sources/AiTaskbarApp/Resources/\(language).lproj/Localizable.strings")
            let contents = try String(contentsOf: file, encoding: .utf8)
            for key in keys {
                expectTrue(contents.contains("\"\(key)\" = "), "missing \(key) in \(language)")
            }
        }
    }

    @Test("AboutView default initializer sets default onQuit")
    func default_initializer() {
        var doneCalled = false
        let view = AboutView(onDone: { doneCalled = true })
        view.onDone()
        expectTrue(doneCalled)
    }

    @Test("the About vendor grid lists every supported LLM")
    func vendor_grid_is_complete() {
        #expect(AboutView.supportedVendors == VendorId.allCases)
        #expect(AboutView.supportedVendors.contains(.typesafe))
    }

    @Test("the description no longer hard-codes a vendor list")
    func description_has_no_vendor_names() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        for language in ["en", "pt-BR", "es"] {
            let file = root.appendingPathComponent("Sources/AiTaskbarApp/Resources/\(language).lproj/Localizable.strings")
            let line = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n").first { $0.hasPrefix("\"about_description\" = ") } ?? ""
            for name in ["Kimi", "OpenRouter", "Z.AI"] {
                #expect(!line.contains(name), "\(language) still names \(name)")
            }
        }
    }
}
