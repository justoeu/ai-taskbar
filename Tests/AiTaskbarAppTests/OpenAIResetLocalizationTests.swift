import Foundation
import Testing

@Suite("OpenAI reset localization")
struct OpenAIResetLocalizationTests {
    @Test("confirmation and every result have translations")
    func keys() throws {
        let keys = ["reset_button", "reset_retry", "reset_busy", "reset_confirm_title",
                    "reset_confirm_button", "reset_cancel", "reset_confirm_message", "reset_done",
                    "reset_done_refresh_pending", "reset_nothing", "reset_no_credit", "reset_cli_unavailable",
                    "reset_unavailable", "reset_account_changed", "reset_auth_required", "reset_failed",
                    "reset_submission_uncertain", "reset_attempt_in_progress"]
        for language in LocalizableStrings.languages {
            let contents = try LocalizableStrings.contents(language)
            for key in keys { expectTrue(LocalizableStrings.defines(key, in: contents), "missing \(key) in \(language)") }
        }
    }
}
