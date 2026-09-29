import Foundation
import Testing
@testable import AiTaskbarApp

/// DUP-MAE-002: the sessions and models counts on the Analytics card were two
/// copies of one block; both now go through `countLabel(sessions:models:)`.
@MainActor
@Suite("Analytics card count label", .serialized)
struct AnalyticsCountLabelTests {
    private static func label(sessions: Int, models: Int) -> String? {
        let previous = L10n.languageOverride
        defer { L10n.languageOverride = previous }
        L10n.languageOverride = "en"
        return VendorAnalyticsCardView.countLabel(sessions: sessions, models: models)
    }

    @Test("sessions win over models")
    func sessions_first() {
        #expect(Self.label(sessions: 3, models: 5) == "3 active sessions")
    }

    @Test("one session is singular")
    func one_session() {
        #expect(Self.label(sessions: 1, models: 5) == "1 active session")
    }

    @Test("models are used when there is no session counter")
    func models_fallback() {
        #expect(Self.label(sessions: 0, models: 2) == "2 models used")
    }

    @Test("one model is singular")
    func one_model() {
        #expect(Self.label(sessions: 0, models: 1) == "1 model used")
    }

    @Test("no counts, no label")
    func no_counts() {
        #expect(Self.label(sessions: 0, models: 0) == nil)
    }
}
