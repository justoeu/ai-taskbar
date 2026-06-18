import Foundation
import SwiftUI

/// Centralized localization lookup with optional config override.
///
/// macOS picks the best available `.lproj` based on system language. When
/// `languageOverride` is set (from `AppConfig.ui.language`), the bundle is
/// re-rooted to that specific `.lproj` regardless of system preference.
///
/// Usage:
///   `Text(L10n.localizedString("loading"))` or `L10n.text("loading")`
///   `L10n.localizedString("today_cost_fmt", args: estimate.usdToday)`
@MainActor
public enum L10n {
    /// Forced language code (e.g. "pt-BR", "en", "es"). nil = follow system.
    /// Set once at app startup from the config.
    public static var languageOverride: String?

    /// Custom resource-bundle locator. Replaces `Bundle.module` because the
    /// SwiftPM-generated accessor uses
    /// `Bundle.main.bundleURL.appendingPathComponent("…bundle")` as its
    /// primary lookup, which works only when the executable runs straight
    /// from `.build/<arch>/release/` (where the resource bundle is a
    /// sibling of the binary). Inside a packaged `.app`,
    /// `Bundle.main.bundleURL` points at the `.app` root, not at
    /// `Contents/Resources/` where the bundle is shipped — so
    /// `Bundle.module` `fatalError`s on first access and the popover
    /// crashes the entire app.
    ///
    /// This lookup tries the conventional locations a packaged `.app`
    /// places resource bundles, falls back to the dev-mode build dir, and
    /// degrades gracefully to `Bundle.main` (untranslated UI is annoying
    /// but the app stays alive) if nothing matches.
    nonisolated(unsafe) private static let resourceBundle: Bundle = {
        let bundleName = "ai-taskbar_AiTaskbarApp.bundle"
        let candidates: [URL?] = [
            // Packaged .app: SwiftPM resource bundle copied to
            // Contents/Resources/ by `make app` / `make app-universal`.
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            // dev mode: `swift run` from .build/<arch>/release/ — the
            // bundle is the sibling of the executable.
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
        ]
        for url in candidates {
            if let url, let b = Bundle(url: url) { return b }
        }
        return .main
    }()

    /// Resolves the effective bundle for string lookups. When the override
    /// names a `.lproj` we have, scope the bundle to it; otherwise fall back
    /// to the resource bundle, which lets macOS pick the best system match.
    ///
    /// Resolution tries multiple forms because SPM lowercases the regional
    /// suffix when materializing `.lproj` folders (`pt-BR.lproj` →
    /// `pt-br.lproj`), but users naturally type the canonical form
    /// ("pt-BR") in config. We try: exact → lowercased → language-only.
    ///
    /// **Memoized.** The candidate resolution runs `Bundle.path(forResource:ofType:)`
    /// (a directory scan) plus an array allocation, which we do NOT want on
    /// every `localizedString` call (50–200 calls/s with the popover open).
    /// The cache is keyed by the current `languageOverride` value — language
    /// changes require a relaunch anyway, so the steady-state is O(1).
    nonisolated(unsafe) private static var cachedBundle: Bundle?
    nonisolated(unsafe) private static var cachedBundleLanguage: String?

    public static var bundle: Bundle {
        if let cached = cachedBundle, cachedBundleLanguage == languageOverride {
            return cached
        }
        let resolved = resolveBundle()
        cachedBundle = resolved
        cachedBundleLanguage = languageOverride
        return resolved
    }

    private static func resolveBundle() -> Bundle {
        guard let override = languageOverride, !override.isEmpty else {
            return resourceBundle
        }
        let candidates: [String] = {
            var out = [override]
            let lower = override.lowercased()
            if lower != override { out.append(lower) }
            // Strip region suffix as a last fallback: "pt-BR" → "pt".
            if let dash = override.firstIndex(of: "-") {
                out.append(String(override[..<dash]))
            }
            return out
        }()
        for code in candidates {
            if let path = resourceBundle.path(forResource: code, ofType: "lproj"),
               let scoped = Bundle(path: path) {
                return scoped
            }
        }
        return resourceBundle
    }

    /// Plain string lookup. Falls back to the key itself when there's no
    /// translation in any bundle.
    public static func localizedString(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Formatted string lookup. The translation is treated as a format
    /// string and applied with the supplied args.
    public static func localizedString(_ key: String, _ args: CVarArg...) -> String {
        let template = bundle.localizedString(forKey: key, value: key, table: nil)
        return String(format: template, arguments: args)
    }

    /// SwiftUI Text convenience wrapping the same lookup.
    public static func text(_ key: String) -> Text {
        Text(localizedString(key))
    }

    /// Locale that matches the active override (or `.current` when there's
    /// none). Used to align Apple's locale-sensitive formatters
    /// (`RelativeDateTimeFormatter`, `NumberFormatter`, …) with the
    /// override — otherwise the formatter would emit English "42 sec ago"
    /// even while our own strings render in pt-BR.
    public static var effectiveLocale: Locale {
        if let override = languageOverride, !override.isEmpty {
            return Locale(identifier: override)
        }
        return .current
    }
}
