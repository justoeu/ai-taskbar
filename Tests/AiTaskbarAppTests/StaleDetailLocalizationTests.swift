import Foundation
import Testing
@testable import AiTaskbarCore
import AiTaskbarProviders
@testable import AiTaskbarApp

/// CQ-MAE-005: a stale card's tooltip showed `lastError.body` raw, so a
/// guidance failure read "guidance: Antigravity is not authenticated; ..."
/// in English whatever the UI language.
@MainActor
@Suite("Stale-card tooltip localization", .serialized)
struct StaleDetailLocalizationTests {
    /// Runs the real lifecycle: a cached payload, then a live fetch that
    /// fails with `error`, so the outcome is the stale fallback.
    nonisolated private static func staleOutcome(failingWith error: AppError) async throws -> CachedOutcome<String> {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-staledetail-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cache = DiskCache(vendor: .gemini, baseDir: tmp, ttl: 600)
        try cache.writePayload(Data("cached".utf8))
        return try await CachedFetch(cache: cache).run(
            forceRefresh: true,
            decode: { String(decoding: $0, as: UTF8.self) },
            fetch: { throw error })
    }

    private static func withLanguage<T>(_ language: String, _ body: () throws -> T) rethrows -> T {
        let previous = L10n.languageOverride
        defer { L10n.languageOverride = previous }
        L10n.languageOverride = language
        return try body()
    }

    @Test("a guidance failure's tooltip is the localized guidance (pt-BR)")
    func guidance_tooltip_is_localized() async throws {
        let outcome = try await Self.staleOutcome(failingWith: .guidance(.antigravityNotAuthenticated))
        let text = Self.withLanguage("pt-BR") { VendorNoticeText.staleDetail(for: outcome.lastError) }
        #expect(text == "Antigravity não autenticado — execute 'agy' no Terminal para entrar.")
    }

    @Test("a guidance failure's tooltip is the localized guidance (en)")
    func guidance_tooltip_is_localized_en() async throws {
        let outcome = try await Self.staleOutcome(failingWith: .guidance(.antigravityNotAuthenticated))
        let text = Self.withLanguage("en") { VendorNoticeText.staleDetail(for: outcome.lastError) }
        #expect(text == "Antigravity not authenticated — run 'agy' in Terminal to log in.")
    }

    @Test("a guidance failure keeps its 401 so the re-login banner still fires")
    func guidance_keeps_status() async throws {
        let outcome = try await Self.staleOutcome(failingWith: .guidance(.antigravityNotAuthenticated))
        #expect(outcome.lastError?.status == 401)
    }

    @Test("a non-guidance failure keeps its diagnostic in the tooltip")
    func http_tooltip_keeps_body() async throws {
        let outcome = try await Self.staleOutcome(failingWith: .http(status: 503, body: "upstream down"))
        #expect(VendorNoticeText.staleDetail(for: outcome.lastError) == "upstream down")
    }

    @Test("no captured error falls back to the generic stale hint")
    func missing_error_uses_stale_help() {
        let text = VendorNoticeText.staleDetail(for: nil)
        #expect(text == L10n.localizedString("stale_help"))
    }
}
