# Changelog

All notable changes to this project are documented in this file.
The format follows the release notes pattern from [GitHub Releases](https://github.com/justoeu/ai-taskbar/releases).

---

## [v0.20.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.20.0) - 2026-09-20

### ✨ Features

-  add Gemini Antigravity and Grok/xAI quota monitoring with settings status indicators (#21)

---

**Full diff:** [`v0.19.0...v0.20.0`](https://github.com/justoeu/ai-taskbar/compare/v0.19.0...v0.20.0)

---

## [v0.19.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.19.0) - 2026-09-14

### ✨ Features

-  treat Codex credits as a quantity, with a self-correcting progress bar (#20)

---

**Full diff:** [`v0.18.2...v0.19.0`](https://github.com/justoeu/ai-taskbar/compare/v0.18.2...v0.19.0)

---

## [v0.18.2](https://github.com/justoeu/ai-taskbar/releases/tag/v0.18.2) - 2026-09-09

### 🐛 Fixes

-  read Claude Keychain item via /usr/bin/security when the direct read is ACL-blocked (#19)

---

**Full diff:** [`v0.18.1...v0.18.2`](https://github.com/justoeu/ai-taskbar/compare/v0.18.1...v0.18.2)

---

## [v0.18.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.18.1) - 2026-09-07

### 🧰 Maintenance

-  use toolchain Testing and harden validation (#18)

---

**Full diff:** [`v0.18.0...v0.18.1`](https://github.com/justoeu/ai-taskbar/compare/v0.18.0...v0.18.1)

---

## [v0.18.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.18.0) - 2026-09-06

### ✨ Features

-  offer confirmed OpenAI earned resets above 90 percent
-  surface current LLM models
-  add secondary service status adapters
-  add service status app panel
-  add Statuspage service status providers
-  add service status core domain

### 🐛 Fixes

-  read native Codex account identity for resets
-  expire stale status fallbacks and align health presentation
-  preserve unverified status during refresh
-  authorize exact Claude credentials through native macOS consent
-  let macOS authorize Claude keychain partitions natively
-  explain rejected login keychain password
-  persist Claude Keychain authorization
-  omit vendors without status pages
-  accept xAI RSS atom self link
-  refine service status indicators
-  harden service status monitoring

### 🧰 Maintenance

-  design provider status panel

---

**Full diff:** [`v0.17.3...v0.18.0`](https://github.com/justoeu/ai-taskbar/compare/v0.17.3...v0.18.0)

---

## [v0.17.3](https://github.com/justoeu/ai-taskbar/releases/tag/v0.17.3) - 2026-08-02

### 🐛 Fixes

-  close remaining ultra-deep OPEN findings (#15)

---

**Full diff:** [`v0.17.2...v0.17.3`](https://github.com/justoeu/ai-taskbar/compare/v0.17.2...v0.17.3)

---

## [v0.17.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.17.1) - 2026-07-26

### 🐛 Fixes

-  take the opencode scan off the critical path for the Models section

---

**Full diff:** [`v0.17.0...v0.17.1`](https://github.com/justoeu/ai-taskbar/compare/v0.17.0...v0.17.1)

---

## [v0.17.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.17.0) - 2026-07-26

### ✨ Features

-  attribute opencode usage to the vendor that billed it

---

**Full diff:** [`v0.16.1...v0.17.0`](https://github.com/justoeu/ai-taskbar/compare/v0.16.1...v0.17.0)

---

## [v0.16.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.16.1) - 2026-07-26

### ✨ Features

- price Opus 5 and read Codex cost from rollout transcripts

### 🐛 Fixes

- make universal-check able to fail, and put it in the release path
- unify the toolchain the release builds with, which had drifted
- the warnings ratchet was blind — it grepped the wrong stream
- correct the warnings gate — it was measuring the wrong machine
- repair the test suite's assertions, then fix what they were hiding

### 🧰 Maintenance

- get the tree to zero compiler warnings, and ratchet it there

---

**Full diff:** [`v0.15.1...v0.16.1`](https://github.com/justoeu/ai-taskbar/compare/v0.15.1...v0.16.1)

---

## [v0.16.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.16.0) - 2026-07-25

### ✨ Features

- feat: price Opus 5 and read Codex cost from rollout transcripts

### 🐛 Fixes

- fix: the warnings ratchet was blind — it grepped the wrong stream
- fix: correct the warnings gate — it was measuring the wrong machine
- fix: repair the test suite's assertions, then fix what they were hiding

### 🧰 Maintenance

- Merge pull request #9 from justoeu/feat/opus-5-pricing-and-codex-rollout-scanner
- chore: get the tree to zero compiler warnings, and ratchet it there
- docs: explain OAuth recovery actions [skip release]

---

**Full diff:** [`v0.15.1...v0.16.0`](https://github.com/justoeu/ai-taskbar/compare/v0.15.1...v0.16.0)

---

## [v0.15.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.15.1) - 2026-07-13

### 🐛 Fixes

-  show Claude re-login after 401
-  recover Claude credentials after 401
-  stabilize Claude authorization and rate limits

---

**Full diff:** [`v0.15.0...v0.15.1`](https://github.com/justoeu/ai-taskbar/compare/v0.15.0...v0.15.1)

---

## [v0.15.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.15.0) - 2026-07-11

### ✨ Features

-  surface Claude model-scoped windows (Fable) + usage credits

### 🐛 Fixes

-  surface Keychain ACL block instead of masking it as "not found"

### ♻️ Refactor

-  harden scoped-window filter + clamp money decimals (PR review)

---

**Full diff:** [`v0.14.0...v0.15.0`](https://github.com/justoeu/ai-taskbar/compare/v0.14.0...v0.15.0)

---

## [v0.14.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.14.0) - 2026-07-11

### ✨ Features

-  suppress Keychain password prompts for good (partition-list dialog)

---

**Full diff:** [`v0.13.0...v0.14.0`](https://github.com/justoeu/ai-taskbar/compare/v0.13.0...v0.14.0)

---

## [v0.13.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.13.0) - 2026-07-11

### ✨ Features

-  cache Anthropic Keychain reads and clarify ACL regression UX

---

**Full diff:** [`v0.12.0...v0.13.0`](https://github.com/justoeu/ai-taskbar/compare/v0.12.0...v0.13.0)

---

## [v0.12.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.12.0) - 2026-07-11

### ✨ Features

-  add xAI management-billing provider and reorderable vendor cards

---

**Full diff:** [`v0.11.0...v0.12.0`](https://github.com/justoeu/ai-taskbar/compare/v0.11.0...v0.12.0)

---

## [v0.11.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.11.0) - 2026-07-07

### ✨ Features

-  menu-bar % only counts expanded (open) cards (#7)

---

**Full diff:** [`v0.10.1...v0.11.0`](https://github.com/justoeu/ai-taskbar/compare/v0.10.1...v0.11.0)

---

## [v0.10.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.10.1) - 2026-07-05

### 🧰 Maintenance

-  sync AGENTS.md with CLAUDE.md (Gemini limitation note)

---

**Full diff:** [`v0.10.0...v0.10.1`](https://github.com/justoeu/ai-taskbar/compare/v0.10.0...v0.10.1)

---

## [v0.10.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.10.0) - 2026-07-05

### ✨ Features

- feat: OpenRouter per-model breakdown + daily/weekly windows

---

**Full diff:** [`v0.9.1...v0.10.0`](https://github.com/justoeu/ai-taskbar/compare/v0.9.1...v0.10.0)

---

## [v0.9.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.9.1) - 2026-07-04

### 🐛 Fixes

-  make in-app Keychain authorize idempotent

---

**Full diff:** [`v0.9.0...v0.9.1`](https://github.com/justoeu/ai-taskbar/compare/v0.9.0...v0.9.1)

---

## [v0.9.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.9.0) - 2026-07-02

### ✨ Features

-  one-click in-app Keychain authorization + clickable field help

---

**Full diff:** [`v0.8.1...v0.9.0`](https://github.com/justoeu/ai-taskbar/compare/v0.8.1...v0.9.0)

---

## [v0.8.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.8.1) - 2026-07-02

### 🐛 Fixes

-  correct the partition-list remediation hint

---

**Full diff:** [`v0.8.0...v0.8.1`](https://github.com/justoeu/ai-taskbar/compare/v0.8.0...v0.8.1)

---

## [v0.8.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.8.0) - 2026-07-02

### ✨ Features

-  developer credit in About + clamp reset countdown after zero

### 🐛 Fixes

-  double hyphen in entitlements XML comment broke codesign

### 🧰 Maintenance

-  sign and publish DMGs locally; CI only validates and drafts

---

**Full diff:** [`v0.7.2...v0.8.0`](https://github.com/justoeu/ai-taskbar/compare/v0.7.2...v0.8.0)

---

## [v0.7.2](https://github.com/justoeu/ai-taskbar/releases/tag/v0.7.2) - 2026-07-01

### 🐛 Fixes

-  replace field-help popover with an in-place banner

---

**Full diff:** [`v0.7.1...v0.7.2`](https://github.com/justoeu/ai-taskbar/compare/v0.7.1...v0.7.2)

### Asset checksum
```
SHA256: 4b19cfc78d175d7a3c80192bbaadf9385cf338c512aee6abb724ad1d0b6020f9
```

---

## [v0.7.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.7.1) - 2026-07-01

### 🐛 Fixes

-  stop field-help popover from expanding to full screen height

---

**Full diff:** [`v0.7.0...v0.7.1`](https://github.com/justoeu/ai-taskbar/compare/v0.7.0...v0.7.1)

### Asset checksum
```
SHA256: 1b5a9486f53eaa7e936450007fa5261d103a9d3b96a9ef301dc071cfce654ece
```

---

## [v0.7.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.7.0) - 2026-07-01

### ✨ Features

-  add Claude Sonnet 5 and GPT-5.6 to PricingTable

---

**Full diff:** [`v0.6.1...v0.7.0`](https://github.com/justoeu/ai-taskbar/compare/v0.6.1...v0.7.0)

### Asset checksum
```
SHA256: 137ecc92733286ac9d48613467d6ccb145f9715e75477b5d32a61834b98cfc4d
```

---

## [v0.6.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.6.1) - 2026-06-25

### 🐛 Fixes

-  remove non-Sendable deinit that broke the release build under Swift 6

---

**Full diff:** [`v0.6.0...v0.6.1`](https://github.com/justoeu/ai-taskbar/compare/v0.6.0...v0.6.1)

### Asset checksum
```
SHA256: 7adb39f0aa87b27c4db829b05e978499fd10dd697bee2e61491b5aa772562c96
```

---

## [v0.5.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.5.1) - 2026-06-21

### 🐛 Fixes

-  classify session/weekly by window unit code, not nextResetTime

---

**Full diff:** [`v0.5.0...v0.5.1`](https://github.com/justoeu/ai-taskbar/compare/v0.5.0...v0.5.1)

### Asset checksum
```
SHA256: 451f6ffedb8e6db63cb44bfb16d1dd06feba3ec076ef9e29558175b99352255d
```

---

## [v0.5.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.5.0) - 2026-06-20

### ✨ Features

-  add prepaid-balance provider

---

**Full diff:** [`v0.4.8...v0.5.0`](https://github.com/justoeu/ai-taskbar/compare/v0.4.8...v0.5.0)

### Asset checksum
```
SHA256: 8e493b072a302e0197511b7da710d52d4c81c8a986096aa99a323bbfdb58b2f1
```

---

## [v0.4.8](https://github.com/justoeu/ai-taskbar/releases/tag/v0.4.8) - 2026-06-20

### 🐛 Fixes

-  surface per-model web-tool usage in popover

---

**Full diff:** [`v0.4.7...v0.4.8`](https://github.com/justoeu/ai-taskbar/compare/v0.4.7...v0.4.8)

### Asset checksum
```
SHA256: 06728ee0a55bf7df6897191e6bbcd780f4e9d3d73204afb952ce252893999c6c
```

---

## [v0.4.7](https://github.com/justoeu/ai-taskbar/releases/tag/v0.4.7) - 2026-06-19

### 🐛 Fixes

-  app crashes on macOS 26 (Tahoe) at launch + settings UI improvements

---

**Full diff:** [`v0.4.6...v0.4.7`](https://github.com/justoeu/ai-taskbar/compare/v0.4.6...v0.4.7)

### Asset checksum
```
SHA256: c2dc949d6e8954b145c4fb2d5c845851679b7ec48bda040921aad0cc037ff2ac
```

---

## [v0.4.6](https://github.com/justoeu/ai-taskbar/releases/tag/v0.4.6) - 2026-06-19

### 🐛 Fixes

-  fetch-depth 0 + prev-tag fallback so changelog is non-empty

---

**Full diff:** [`v0.4.5...v0.4.6`](https://github.com/justoeu/ai-taskbar/compare/v0.4.5...v0.4.6)

### Asset checksum
```
SHA256: 57355ef331e0ab4f15f9f56841b0f01c12b59cfc2402478ecc2b0337bda21fe3
```

---

## [v0.4.5](https://github.com/justoeu/ai-taskbar/releases/tag/v0.4.5) - 2026-06-19

### 🐛 Fixes

- DMG layout, ~/Downloads target, generated changelog, drop 'inspired by'

### 🧰 Maintenance

- release notes now point users at the `Applications` symlink baked into the DMG

---

**Full diff:** [`v0.4.4...v0.4.5`](https://github.com/justoeu/ai-taskbar/compare/v0.4.4...v0.4.5)

### Asset checksum
```
SHA256: b4c66f173f4b696027693c10ccc496df0cc93a6ed899be4536d1d338b82a61fa
```

---

## [v0.4.4](https://github.com/justoeu/ai-taskbar/releases/tag/v0.4.4) - 2026-06-19

### 🐛 Fixes

- fix(settings): accordion opens one vendor at a time + save closes with feedback

---

**Full diff:** [`v0.4.3...v0.4.4`](https://github.com/justoeu/ai-taskbar/compare/v0.4.3...v0.4.4)

---

## [v0.4.3](https://github.com/justoeu/ai-taskbar/releases/tag/v0.4.3) - 2026-06-19

### 🐛 Fixes

- fix(settings): layout, vendor sort, working accordions, help text

---

**Full diff:** [`v0.4.2...v0.4.3`](https://github.com/justoeu/ai-taskbar/compare/v0.4.2...v0.4.3)

---

## [v0.4.2](https://github.com/justoeu/ai-taskbar/releases/tag/v0.4.2) - 2026-06-19

### 🐛 Fixes

- fix(ci): wrap ConfigWatcher.adoptCurrentAsBaseline in MainActor.assumeIsolated

---

**Full diff:** [`v0.4.1...v0.4.2`](https://github.com/justoeu/ai-taskbar/compare/v0.4.1...v0.4.2)

---

## [v0.4.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.4.1) - 2026-06-19

### 🐛 Fixes

- fix(ci): mark SecretBox.key as nonisolated(unsafe)

---

**Full diff:** [`v0.4.0...v0.4.1`](https://github.com/justoeu/ai-taskbar/compare/v0.4.0...v0.4.1)

---

## [v0.4.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.4.0) - 2026-06-19

### ✨ Features

- feat(settings): in-app Settings UI replacing direct config.toml editing

---

**Full diff:** [`v0.3.1...v0.4.0`](https://github.com/justoeu/ai-taskbar/compare/v0.3.1...v0.4.0)

---

## [v0.3.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.3.1) - 2026-06-18

### 🐛 Fixes

- fix(ci): ConfigWatcher.deinit uses MainActor.assumeIsolated

---

**Full diff:** [`v0.3.0...v0.3.1`](https://github.com/justoeu/ai-taskbar/compare/v0.3.0...v0.3.1)

---

## [v0.3.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.3.0) - 2026-06-18

### ✨ Features

- feat: security hardening + Swift 6 + perf sweep

---

**Full diff:** [`v0.2.3...v0.3.0`](https://github.com/justoeu/ai-taskbar/compare/v0.2.3...v0.3.0)

---

## [v0.2.3](https://github.com/justoeu/ai-taskbar/releases/tag/v0.2.3) - 2026-06-18

### 🧰 Maintenance

- Fix Z.AI usage decode: match real quota/limit wire schema (#6)
- docs: explain why Gemini has no usable usage/quota integration [skip release]

---

**Full diff:** [`v0.2.2...v0.2.3`](https://github.com/justoeu/ai-taskbar/compare/v0.2.2...v0.2.3)

---

## [v0.2.2](https://github.com/justoeu/ai-taskbar/releases/tag/v0.2.2) - 2026-06-14

### 🧰 Maintenance

- Merge pull request #4 from justoeu/fix/keychain-freshest-and-pricing
- Fix Anthropic 401 (stale Keychain item) + correct cost pricing

---

**Full diff:** [`v0.2.1...v0.2.2`](https://github.com/justoeu/ai-taskbar/compare/v0.2.1...v0.2.2)

---

## [v0.2.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.2.1) - 2026-06-14

### 🧰 Maintenance

- ci: auto-tag + release on main push; bump 0.2.0 → 0.2.1 [skip release]
- Merge pull request #3 from justoeu/fix/anthropic-readonly-credentials
- Apply review fixes: read-only by default for both OAuth providers
- Anthropic: read-only credentials by default (no token rotation)

---

**Full diff:** [`v0.2.0...v0.2.1`](https://github.com/justoeu/ai-taskbar/compare/v0.2.0...v0.2.1)

---

## [v0.2.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.2.0) - 2026-05-31

### ✨ Features

- **Sixth provider — Google Gemini:** Uses `GET /v1beta/models` as an authenticated heartbeat. Auth via `x-goog-api-key` header.
- **Default refresh cadence raised from 150 s → 300 s (5 min):** Floor is 15 s; override via `[ui] refresh_interval_seconds = …`.
- **Forward countdown in the popover header:** "Próx. em 4:59" replaces the old "atualizado há …".
- **Rate-limit back-off:** When any vendor ends in HTTP 429, adds 60 s backoff to next sleep.
- **Per-provider exponential cooldown:** Skipped for 5, 10, 20, 40, up to 60 minutes when rate-limited.
- **Cache TTL derived from cadence:** `max(15, refresh_interval_seconds − 5)`.
- **Keychain write prompt suppression:** `KeychainCredentialReader.writeBack` silences password prompts.

---

**Full diff:** [`v0.1.5...v0.2.0`](https://github.com/justoeu/ai-taskbar/compare/v0.1.5...v0.2.0)

---

## [v0.1.5](https://github.com/justoeu/ai-taskbar/releases/tag/v0.1.5) - 2026-05-29

### 🧰 Maintenance

- Solid popover background + bump v0.1.5

---

**Full diff:** [`v0.1.4...v0.1.5`](https://github.com/justoeu/ai-taskbar/compare/v0.1.4...v0.1.5)

---

## [v0.1.4](https://github.com/justoeu/ai-taskbar/releases/tag/v0.1.4) - 2026-05-29

### 🧰 Maintenance

- Bump fonts +2 steps across the popover — v0.1.4

---

**Full diff:** [`v0.1.3...v0.1.4`](https://github.com/justoeu/ai-taskbar/compare/v0.1.3...v0.1.4)

---

## [v0.1.3](https://github.com/justoeu/ai-taskbar/releases/tag/v0.1.3) - 2026-05-29

### 🧰 Maintenance

- Bump v0.1.3 — internal quality release
- Close INFO-1: dependency-invert KeychainCredentialReader via protocol
- Seed real Keychain entries in tests to widen CI coverage margin
- Coverage script: float comparison + tighten margin
- CI: switch to macos-15 (Xcode 16 / Swift 6) and gate coverage at 90%
- Coverage ≥90% + golden tests for vendor wire types

---

**Full diff:** [`v0.1.2...v0.1.3`](https://github.com/justoeu/ai-taskbar/compare/v0.1.2...v0.1.3)

---

## [v0.1.2](https://github.com/justoeu/ai-taskbar/releases/tag/v0.1.2) - 2026-05-28

### 🧰 Maintenance

- Stop using Bundle.module — bump v0.1.2

---

**Full diff:** [`v0.1.1...v0.1.2`](https://github.com/justoeu/ai-taskbar/compare/v0.1.1...v0.1.2)

---

## [v0.1.1](https://github.com/justoeu/ai-taskbar/releases/tag/v0.1.1) - 2026-05-28

### 🧰 Maintenance

- Fix Bundle.module crash on .app launch + bump v0.1.1

---

**Full diff:** [`v0.1.0...v0.1.1`](https://github.com/justoeu/ai-taskbar/compare/v0.1.0...v0.1.1)

---

## [v0.1.0](https://github.com/justoeu/ai-taskbar/releases/tag/v0.1.0) - 2026-05-28

### ✨ Initial Release

**Core**
- 5 LLM providers — Anthropic Claude, OpenAI Codex/ChatGPT, OpenRouter, Z.AI (GLM), Kimi (Moonshot)
- OAuth auto-refresh for Anthropic + OpenAI using their official `client_id`s
- Per-vendor caches with 150-second TTL and 7-day stale fallback

**UI**
- SwiftUI `MenuBarExtra` with accordion popover
- 24-hour sparkline with dashed threshold lines (warning + critical), current-value annotation, and peak marker
- Color-coded gauge in the menu bar (rotating mode optional)
- Per-model cost breakdown (today / last 7 days side-by-side)
- About panel with version + GitHub Releases update checker

**i18n**
- 3 languages out of the box (`en`, `pt-BR`, `es`) with `[ui] language = ...` config override

**Security**
- macOS Keychain reader with single-pass query
- `~/.codex/auth.json` write-back with atomic `0o600` chmod before rename
- All cache/config files chmod `0o600`, support dir `0o700`
- OpenAI cache strips PII (`user_id`/`account_id`/`email`)
- Host allow-listing (SSRF defense) and TOCTOU symlink refusal
