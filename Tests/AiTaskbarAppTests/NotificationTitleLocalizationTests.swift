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
}
