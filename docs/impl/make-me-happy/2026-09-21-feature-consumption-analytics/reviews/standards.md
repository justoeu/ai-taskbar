# Standards Review

**Commit Range:** `96ef7a9...HEAD` (branch `feature/consumption-analytics`)  
**Standards Sources:** `AGENTS.md`, `catalogs/fowler-smells.md`

## 1. Documented Standards Compliance (AGENTS.md)
- **Swift 6 Concurrency:** `AnalyticsStore` is strictly annotated `@MainActor`. All domain models (`AnalyticsTimeframe`, `PeakDayRecord`, `VendorAnalyticsSummary`, `VendorShare`, `GlobalAnalyticsSnapshot`) conform to `Sendable` and `Hashable`/`Identifiable`.
- **Credits Separation:** Codex credits invariants are strictly preserved. Neither `PricingTable.xai` nor `PricingTable.gemini` touches credit logic. Monetary estimations are token-based.
- **Testing Conventions:** Tests use Swift Testing (`@Test`, `#expect`), atomic assertions, and no vacuous booleans.
- **Localization:** All user-facing strings in `AnalyticsView`, `VendorAnalyticsCardView`, and `AboutView` are extracted to `Localizable.strings` (`en`, `pt-BR`, `es`).
- **macOS 13+ Compatibility:** Vector donut chart implemented via native SwiftUI `Path.addArc` rather than iOS 17 / macOS 14 `SectorMark`.

## 2. Fowler Smells Evaluation
- **Mysterious Name:** None. Domain types and UI components have clean, explicit names.
- **Duplicated Code:** Formatters for currencies and date strings extracted into `AnalyticsFormatters`.
- **Feature Envy / Data Clumps:** Grouped into cohesive snapshots (`GlobalAnalyticsSnapshot`, `VendorAnalyticsSummary`).
- **Speculative Generality:** Zero unnecessary abstractions; solely implements requested SDD features.

VERDICT: APPROVE
