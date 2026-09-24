# Standards Review

## Findings
- **Swift Concurrency & Actor Isolation:**
  - `UpdateChecker` maintains `@MainActor` isolation for all UI state properties (`status`, `dismissedTag`).
  - Constants (`cadenceInterval`, `lastCheckKey`, `dismissedTagKey`) are explicitly marked `nonisolated public static let` to prevent actor hops and satisfy strict concurrency.
  - In `RefreshScheduler`, `updateCheckLoop` is weak-referenced (`[weak self]`) and properly cancelled in `stop()` and `deinit`, avoiding retain cycles.
  - In `RefreshScheduler`, `updates` is held as `private weak var updates: UpdateChecker?`, matching `store` and `statusStore`.
- **Localization:**
  - All new user-facing strings are extracted to `Localizable.strings` across all three supported locales (`en`, `pt-BR`, `es`). No hardcoded English strings in view bodies.
- **Clean Architecture & Fowler Smells:**
  - Zero Shotgun Surgery: changes cleanly divided into UpdateChecker, RefreshScheduler, and PopoverContentView.
  - Zero Speculative Generality: implemented exactly the 24h cadence, banner presentation, and dismiss functionality specified in the SDD.

VERDICT: APPROVE
