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

    /// Resolves the effective bundle for string lookups. When the override
    /// names a `.lproj` we have, scope the bundle to it; otherwise fall back
    /// to the module bundle, which lets macOS pick the best system match.
    ///
    /// Resolution tries multiple forms because SPM lowercases the regional
    /// suffix when materializing `.lproj` folders (`pt-BR.lproj` →
    /// `pt-br.lproj`), but users naturally type the canonical form
    /// ("pt-BR") in config. We try: exact → lowercased → language-only.
    public static var bundle: Bundle {
        guard let override = languageOverride, !override.isEmpty else {
            return .module
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
            if let path = Bundle.module.path(forResource: code, ofType: "lproj"),
               let scoped = Bundle(path: path) {
                return scoped
            }
        }
        return .module
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
