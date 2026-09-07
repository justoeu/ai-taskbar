import Foundation
import Testing

@Suite("OpenAI reset localization")
struct OpenAIResetLocalizationTests {
    @Test("confirmation and every result have translations")
    func keys() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let keys = ["reset_button", "reset_retry", "reset_busy", "reset_confirm_title",
                    "reset_confirm_button", "reset_cancel", "reset_confirm_message", "reset_done",
                    "reset_done_refresh_pending", "reset_nothing", "reset_no_credit", "reset_cli_unavailable",
                    "reset_unavailable", "reset_account_changed", "reset_auth_required", "reset_failed",
                    "reset_submission_uncertain", "reset_attempt_in_progress"]
        for language in ["en", "pt-BR", "es"] {
            let file = root.appendingPathComponent("Sources/AiTaskbarApp/Resources/\(language).lproj/Localizable.strings")
            let contents = try String(contentsOf: file, encoding: .utf8)
            for key in keys { expectTrue(contents.contains("\"\(key)\" = "), "missing \(key) in \(language)") }
        }
    }
}
