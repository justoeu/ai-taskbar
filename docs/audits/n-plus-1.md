# N+1 audit log

## 2026-10-12 — Meta (Muse) integration (`feature/meta-muse`)

Scope: `git diff main...HEAD` (new vendor, SDD-meta-muse).

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | `MetaProvider.fetchUsage` — exactly one HTTP request per refresh (the mint POST), pinned by `MetaProviderTests.fetch_end_to_end` | — (no N+1) | OK |
| 2 | `MuseSessionScanner` reads one file per session log — inherent to log scanning; bounded by the 7-day `CostWindow`, `mtime` prefilter, byte prefilter and `ScanMemo` replay (unchanged files are not re-read), same as Claude/Codex scanners | LOW (inherent) | Accepted by design |
| 3 | `SettingsView` computed the Meta login probe (auth-file read + Keychain attribute query) on every SwiftUI body pass | MEDIUM (per-render I/O) | **Fixed**: cached in `@State metaLoginDetected`, refreshed on appear / auth-path change (`SettingsView.swift`) |
| 4 | `CostEstimator.refresh` runs the three vendor scanners concurrently (`async let`), fixed fan-out of 3 | — (no N+1) | OK |

No HIGH findings. Backend has no DB/ORM; frontend renders vendor rows from
already-fetched snapshots (no per-row requests).
