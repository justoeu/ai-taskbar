import Foundation
import Testing
@testable import AiTaskbarApp
@testable import AiTaskbarCore

@Suite("MenuBarTooltipBuilder")
@MainActor
struct MenuBarTooltipBuilderTests {
    @Test("all tooltip localization keys exist across all languages")
    func localization_keys_exist() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let keys = [
            "tooltip_daily_reset_fmt",
            "tooltip_weekly_reset_fmt",
            "tooltip_daily_reset_waiting",
            "tooltip_weekly_reset_waiting",
            "time_less_than_minute"
        ]
        for language in ["en", "pt-BR", "es"] {
            let file = root.appendingPathComponent("Sources/AiTaskbarApp/Resources/\(language).lproj/Localizable.strings")
            let contents = try String(contentsOf: file, encoding: .utf8)
            for key in keys {
                expectTrue(contents.contains("\"\(key)\" = "), "missing \(key) in \(language)")
            }
        }
    }

    @Test("fallback when snapshot is nil")
    func nil_snapshot_fallback() {
        let tooltip = MenuBarTooltipBuilder.buildTooltip(
            vendorId: .anthropic,
            snapshot: nil,
            currentPercent: 42
        )
        #expect(tooltip == "Claude: 42%")
    }

    @Test("fallback when no reset windows exist")
    func no_reset_windows_fallback() {
        let snap = VendorSnapshot.deepseek(.init(balance: UsageWindow(label: "Balance", utilizationPercent: 0, resetsAt: nil)))
        let tooltip = MenuBarTooltipBuilder.buildTooltip(
            vendorId: .deepseek,
            snapshot: snap,
            currentPercent: 0
        )
        #expect(tooltip == "DeepSeek: 0%")
    }

    @Test("both daily and weekly windows with countdown in pt-BR")
    func both_windows_countdown_pt_br() {
        let prevLang = L10n.languageOverride
        defer { L10n.languageOverride = prevLang }
        L10n.languageOverride = "pt-BR"

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = UsageWindow(label: "Session", utilizationPercent: 50, resetsAt: now.addingTimeInterval(2 * 3600 + 30 * 60))
        let weekly = UsageWindow(label: "Weekly", utilizationPercent: 20, resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600))
        let snap = VendorSnapshot.anthropic(.init(session: session, weekly: weekly))

        let tooltip = MenuBarTooltipBuilder.buildTooltip(
            vendorId: .anthropic,
            snapshot: snap,
            currentPercent: 50,
            now: now,
            locale: Locale(identifier: "pt_BR")
        )

        let expected = """
        Claude
        Diário: falta 2 horas e 30 minutos
        Semanal: falta 3 dias e 4 horas
        """
        #expect(tooltip == expected)
    }

    @Test("weekly only window with < 24h remaining formats in hours")
    func weekly_only_under_24h_pt_br() {
        let prevLang = L10n.languageOverride
        defer { L10n.languageOverride = prevLang }
        L10n.languageOverride = "pt-BR"

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weekly = UsageWindow(label: "Weekly", utilizationPercent: 65, resetsAt: now.addingTimeInterval(18 * 3600))
        let snap = VendorSnapshot.xai(.init(weekly: weekly))

        let tooltip = MenuBarTooltipBuilder.buildTooltip(
            vendorId: .xai,
            snapshot: snap,
            currentPercent: 65,
            now: now,
            locale: Locale(identifier: "pt_BR")
        )

        let expected = """
        xAI (Grok)
        Semanal: falta 18 horas
        """
        #expect(tooltip == expected)
    }

    @Test("awaiting refresh when resetsAt has passed")
    func awaiting_refresh_pt_br() {
        let prevLang = L10n.languageOverride
        defer { L10n.languageOverride = prevLang }
        L10n.languageOverride = "pt-BR"

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = UsageWindow(label: "Session", utilizationPercent: 95, resetsAt: now.addingTimeInterval(-15))
        let weekly = UsageWindow(label: "Weekly", utilizationPercent: 40, resetsAt: now.addingTimeInterval(2 * 86400))
        let snap = VendorSnapshot.openai(.init(primary: session, secondary: weekly))

        let tooltip = MenuBarTooltipBuilder.buildTooltip(
            vendorId: .openai,
            snapshot: snap,
            currentPercent: 95,
            now: now,
            locale: Locale(identifier: "pt_BR")
        )

        let expected = """
        Codex / ChatGPT
        Diário: aguardando atualização
        Semanal: falta 2 dias
        """
        #expect(tooltip == expected)
    }

    @Test("sub-minute countdown formatting")
    func sub_minute_countdown() {
        let prevLang = L10n.languageOverride
        defer { L10n.languageOverride = prevLang }
        L10n.languageOverride = "pt-BR"

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = UsageWindow(label: "Session", utilizationPercent: 30, resetsAt: now.addingTimeInterval(45))
        let snap = VendorSnapshot.gemini(.init(fiveHour: session, weekly: nil))

        let tooltip = MenuBarTooltipBuilder.buildTooltip(
            vendorId: .gemini,
            snapshot: snap,
            currentPercent: 30,
            now: now,
            locale: Locale(identifier: "pt_BR")
        )

        let expected = """
        Gemini (Google AI)
        Diário: falta menos de 1 minuto
        """
        #expect(tooltip == expected)
    }

    @Test("formatting in English")
    func formatting_in_english() {
        let prevLang = L10n.languageOverride
        defer { L10n.languageOverride = prevLang }
        L10n.languageOverride = "en"

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = UsageWindow(label: "Session", utilizationPercent: 50, resetsAt: now.addingTimeInterval(2 * 3600 + 30 * 60))
        let weekly = UsageWindow(label: "Weekly", utilizationPercent: 20, resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600))
        let snap = VendorSnapshot.anthropic(.init(session: session, weekly: weekly))

        let tooltip = MenuBarTooltipBuilder.buildTooltip(
            vendorId: .anthropic,
            snapshot: snap,
            currentPercent: 50,
            now: now,
            locale: Locale(identifier: "en_US")
        )

        let expected = """
        Claude
        Daily: 2 hours, 30 minutes left
        Weekly: 3 days, 4 hours left
        """
        #expect(tooltip == expected)
    }

    @Test("formatting in Spanish")
    func formatting_in_spanish() {
        let prevLang = L10n.languageOverride
        defer { L10n.languageOverride = prevLang }
        L10n.languageOverride = "es"

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = UsageWindow(label: "Session", utilizationPercent: 50, resetsAt: now.addingTimeInterval(2 * 3600 + 30 * 60))
        let weekly = UsageWindow(label: "Weekly", utilizationPercent: 20, resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600))
        let snap = VendorSnapshot.anthropic(.init(session: session, weekly: weekly))

        let tooltip = MenuBarTooltipBuilder.buildTooltip(
            vendorId: .anthropic,
            snapshot: snap,
            currentPercent: 50,
            now: now,
            locale: Locale(identifier: "es_ES")
        )

        let expected = """
        Claude
        Diario: falta 2 horas y 30 minutos
        Semanal: falta 3 días y 4 horas
        """
        #expect(tooltip == expected)
    }
}
