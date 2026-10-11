import Foundation
import Testing
@testable import AiTaskbarApp

/// BUG-MAE-015: every integer format key is fed a 64-bit Swift `Int`. A `%d`
/// reads only 32 bits of it, so a value past `Int32.max` (for instance an
/// unclamped `notify_at` threshold) rendered as a truncated number.
@MainActor
@Suite("Integer format specifiers are 64-bit", .serialized)
struct IntegerFormatSpecifierTests {
    /// Past `Int32.max`; its low 32 bits are 705032704.
    private static let big = 5_000_000_000

    /// Key -> number of `Int` arguments its call site passes.
    private static let intKeys: [(key: String, arity: Int)] = [
        ("notif_discreet_body_fmt", 1),
        ("service_status_ax_value_fmt", 3),
        ("service_status_duration_fmt", 2),
        ("credits_local_msgs_fmt", 2),
        ("credits_cloud_msgs_fmt", 2),
        ("compare_vs_prev_week_fmt", 1),
        ("compare_vs_prev_day_fmt", 1),
        ("compare_vs_prev_month_fmt", 1),
        ("analytics_models_count", 1),
    ]

    private static func render(_ key: String, _ args: [CVarArg], in language: String) -> String {
        let previous = L10n.languageOverride
        defer { L10n.languageOverride = previous }
        L10n.languageOverride = language
        return String(format: L10n.localizedString(key), arguments: args)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test("the discreet notification body keeps a threshold past Int32.max",
          arguments: ["en", "pt-BR", "es"])
    func discreet_body_is_64_bit(language: String) {
        let body = Self.render("notif_discreet_body_fmt", [Self.big], in: language)
        #expect(body.contains("5000000000%"))
    }

    @Test("every Int-fed key renders each argument past Int32.max",
          arguments: ["en", "pt-BR", "es"])
    func int_keys_are_64_bit(language: String) {
        for (key, arity) in Self.intKeys {
            let args: [CVarArg] = Array(repeating: Self.big, count: arity)
            let text = Self.render(key, args, in: language)
            #expect(Self.occurrences(of: "5000000000", in: text) == arity,
                    "\(language) \(key): \(text)")
        }
    }

    @Test("the reset confirmation keeps a count past Int32.max",
          arguments: ["en", "pt-BR", "es"])
    func reset_confirm_is_64_bit(language: String) {
        let previous = L10n.languageOverride
        defer { L10n.languageOverride = previous }
        L10n.languageOverride = language
        let text = L10n.localizedString("reset_confirm_message", "acct", Self.big)
        #expect(text.contains("5000000000"))
    }

    @Test("WeeklyModelStackedChartView.formatTokens abbreviates accurately")
    func weekly_chart_format_tokens() {
        #expect(WeeklyModelStackedChartView.formatTokens(500) == "500")
        #expect(WeeklyModelStackedChartView.formatTokens(1_500) == "1.5K")
        #expect(WeeklyModelStackedChartView.formatTokens(2_500_000) == "2.5M")
        #expect(WeeklyModelStackedChartView.formatTokens(3_200_000_000) == "3.2B")
    }
}
