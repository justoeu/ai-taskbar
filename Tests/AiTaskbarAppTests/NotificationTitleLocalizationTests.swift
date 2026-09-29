import Foundation
import Testing
import AiTaskbarCore
@testable import AiTaskbarApp

/// CQ-MAE-012: the non-discreet notification title was a hard-coded English
/// sentence ("… at 92%") while its body was localized.
@MainActor
@Suite("Notification title localization", .serialized)
struct NotificationTitleLocalizationTests {
    private static let window = UsageWindow(label: "5h", utilizationPercent: 92.4)

    private static func title(in language: String) -> String {
        let previous = L10n.languageOverride
        defer { L10n.languageOverride = previous }
        L10n.languageOverride = language
        return NotificationService.title(vendor: .anthropic, window: window)
    }

    @Test("en title")
    func title_en() {
        #expect(Self.title(in: "en") == "\(VendorId.anthropic.displayName) — 5h at 92%")
    }

    @Test("pt-BR title")
    func title_pt_br() {
        #expect(Self.title(in: "pt-BR") == "\(VendorId.anthropic.displayName) — 5h em 92%")
    }

    @Test("es title")
    func title_es() {
        #expect(Self.title(in: "es") == "\(VendorId.anthropic.displayName) — 5h al 92%")
    }

    /// CQ-MAE-018: the title truncated (92.9 -> 92) while the card rounds.
    @Test("the title rounds the percent the way the card does")
    func title_rounds_like_card() {
        let previous = L10n.languageOverride
        defer { L10n.languageOverride = previous }
        L10n.languageOverride = "en"
        let window = UsageWindow(label: "5h", utilizationPercent: 92.9)
        #expect(NotificationService.title(vendor: .anthropic, window: window)
            == "\(VendorId.anthropic.displayName) — 5h at 93%")
    }
}

/// CQ-MAE-018: one rounding rule for every whole-percent label.
@Suite("PercentText")
struct PercentTextTests {
    @Test("rounds half up to the nearest whole percent")
    func rounds() {
        #expect(PercentText.whole(92.9) == 93)
    }

    @Test("keeps a value below .5 on its floor")
    func rounds_down() {
        #expect(PercentText.whole(92.4) == 92)
    }

    @Test("formats with a percent sign")
    func formats() {
        #expect(PercentText.format(92.9) == "93%")
    }

    @Test("saturates a non-finite value instead of trapping")
    func saturates() {
        #expect(PercentText.whole(.infinity) == Int.max)
    }
}
