# Spec Summary — Consumption Analytics, Grok 4.7 Pricing and UI Refinements

## 1. Goal
Provide a comprehensive analytics dashboard within the AI Taskbar menu-bar popover, offering cross-LLM consumption percentages, dollar costs, timeframe comparisons (Daily, Weekly, Monthly), peak usage day detection with a flame icon (`🔥`), sessions count, and per-model cost breakdowns. Expand pricing to include Grok 4.7 and Gemini models, reorganize popover toolbar icons, and relocate application exit to AboutView behind a confirmation prompt.

## 2. Actors & Components
- **UsageHistoryStore**: Provides 90-day historical time-series data of vendor quota percentages.
- **Scanners (CostEstimator & OpencodeScanner)**: Parse local Claude and Codex sessions as well as Opencode SQLite database turns to attribute token counts and financial costs.
- **PricingTable**: Maps model identifiers to token pricing for OpenAI, Anthropic, xAI (Grok 4.7), Gemini, and Z.AI.
- **AnalyticsAggregator & AnalyticsStore**: Aggregates multi-source metrics into snapshot representations (`GlobalAnalyticsSnapshot`, `VendorAnalyticsSummary`).
- **AnalyticsView & DonutChartView**: Renders vector-based dual donut charts (macOS 13+ compatible) and per-vendor summary cards.
- **PopoverContentView & AboutView**: Reordered toolbar actions and modal quit confirmation.

## 3. Contracts & Wire Types
- Preserves all frozen vendor wire types without alteration.
- Introduces new value types: `AnalyticsTimeframe`, `VendorAnalyticsSummary`, `PeakDayRecord`, `GlobalAnalyticsSnapshot`, `VendorShare`.
- Pure SwiftUI drawing (`Path`, `StrokeStyle`) for macOS 13 compatibility (avoiding macOS 14+ `SectorMark`).

## 4. Out of Scope
- Background system daemons.
- Remote telemetry / cloud metrics synchronization (all computations remain strictly local).
- Third-party chart library dependencies.
