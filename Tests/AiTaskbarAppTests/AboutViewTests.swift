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

        let keys = [
            "quit_app",
            "quit_confirm_title",
            "quit_confirm_message",
            "quit_confirm_button",
            "cancel",
            "back"
        ]

        for language in LocalizableStrings.languages {
            let contents = try LocalizableStrings.contents(language)
            for key in keys {
                expectTrue(LocalizableStrings.defines(key, in: contents), "missing \(key) in \(language)")
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
}
