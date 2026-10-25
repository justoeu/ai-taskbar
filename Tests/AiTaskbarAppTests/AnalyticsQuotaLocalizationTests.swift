import Foundation
import Testing
import AiTaskbarCore
@testable import AiTaskbarApp

/// CQ-MAE-022: the Analytics peak-day line and the card appended a literal
/// English " quota" to an otherwise localized string.
@MainActor
@Suite("Analytics quota localization", .serialized)
struct AnalyticsQuotaLocalizationTests {
    private static let record = PeakDayRecord(date: Date(timeIntervalSince1970: 1_700_000_000),
                                              costUSD: 0, utilizationPercent: 84.6,
                                              isHistoricalPeak: true)

    private static func inLanguage<T>(_ language: String, _ body: () -> T) -> T {
        let previous = L10n.languageOverride
        defer { L10n.languageOverride = previous }
        L10n.languageOverride = language
        return body()
    }

    @Test("en peak-day line")
    func peak_day_en() {
        #expect(Self.inLanguage("en") { AnalyticsFormatters.peakDayText(Self.record) }
            .hasSuffix("(85% quota)"))
    }

    @Test("pt-BR peak-day line")
    func peak_day_pt_br() {
        #expect(Self.inLanguage("pt-BR") { AnalyticsFormatters.peakDayText(Self.record) }
            .hasSuffix("(85% da quota)"))
    }

    @Test("es peak-day line")
    func peak_day_es() {
        #expect(Self.inLanguage("es") { AnalyticsFormatters.peakDayText(Self.record) }
            .hasSuffix("(85% de la cuota)"))
    }

    @Test("pt-BR peak-day line with cost")
    func peak_day_cost_pt_br() {
        let record = PeakDayRecord(date: Self.record.date, costUSD: 12.5,
                                   utilizationPercent: 84.6, isHistoricalPeak: true)
        #expect(Self.inLanguage("pt-BR") { AnalyticsFormatters.peakDayText(record) }
            .hasSuffix("($12.50 / 85% da quota)"))
    }

    @Test("pt-BR token peak-day line shows tokens and cost, never a quota")
    func peak_day_tokens_pt_br() {
        let record = PeakDayRecord(date: Self.record.date, costUSD: 1_600,
                                   utilizationPercent: 0, isHistoricalPeak: true,
                                   tokens: 4_200_000_000)
        #expect(Self.inLanguage("pt-BR") { AnalyticsFormatters.peakDayText(record) }
            .hasSuffix("(4.2B tokens · $1,600.00)"))
    }

    @Test("en token peak-day line without cost shows tokens only")
    func peak_day_tokens_no_cost_en() {
        let record = PeakDayRecord(date: Self.record.date, costUSD: 0,
                                   utilizationPercent: 0, isHistoricalPeak: true,
                                   tokens: 12_500)
        #expect(Self.inLanguage("en") { AnalyticsFormatters.peakDayText(record) }
            .hasSuffix("(12.5K tokens)"))
    }

    @Test("pt-BR card quota label")
    func card_quota_pt_br() {
        #expect(Self.inLanguage("pt-BR") { AnalyticsFormatters.quotaText(84.6) } == "85% da quota")
    }
}
