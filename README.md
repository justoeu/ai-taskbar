# AI Taskbar

<p align="center">
  <img src="docs/icon_preview.png" alt="AI Taskbar icon" width="128" height="128"/>
</p>

<p align="center">
  <b>Native macOS menu-bar tracker for LLM usage across 5 providers.</b><br/>
  Anthropic Claude · OpenAI Codex/ChatGPT · OpenRouter · Z.AI (GLM) · Kimi (Moonshot)
</p>

<p align="center">
  <a href="https://github.com/justoeu/ai-taskbar/releases"><img src="https://img.shields.io/github/v/release/justoeu/ai-taskbar?include_prereleases&label=release&style=flat-square" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/arch-universal-purple?style=flat-square" alt="Universal binary">
  <img src="https://img.shields.io/badge/swift-5.10-orange?style=flat-square" alt="Swift 5.10">
</p>

---

## What you get

A gauge icon in your menu bar showing the **highest utilization** across every LLM you have credentials for. Click it for a per-provider breakdown:

- **Plan label** ("Claude Max 20x", "ChatGPT Plus", "GLM Lite")
- **Per-window utilization** with color thresholds (green → yellow → red)
- **Reset countdown** ("resets 4 hrs, 12 min")
- **24-hour sparkline** with dashed threshold lines, current value, and peak marker
- **Daily + 7-day cost estimates** computed locally from your CLI logs
- **Per-model breakdown** ("opus-4-7 $1850 / haiku-4-5 $245")
- **Click the LLM name** → opens that vendor's official dashboard
- **Locked card with explanation** when a provider has no credentials

The app runs entirely on-device — **no telemetry, no remote logging, no auto-update without your click**.

## Table of contents

- [Install](#install)
- [Setup per provider](#setup-per-provider)
- [What's in this version](#whats-in-this-version)
- [How it works](#how-it-works)
- [Configuration](#configuration)
- [Where data lives](#where-data-lives)
- [Privacy & security](#privacy--security)
- [Build from source](#build-from-source)
- [Releasing a new version](#releasing-a-new-version)
- [Architecture](#architecture)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## Install

### Option 1 — Download the DMG (recommended)

1. Download the latest `ai-taskbar-X.Y.Z.dmg` from [Releases](https://github.com/justoeu/ai-taskbar/releases).
2. Open the DMG and drag **AI Taskbar.app** to **/Applications**.
3. **First launch only** — Gatekeeper will warn it's from an unidentified developer. Either:
   - **Right-click `AiTaskbar.app` → Open**, then click *Open* in the dialog.
   - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/AiTaskbar.app`

The DMG ships a **universal binary** that works on Apple Silicon and Intel Macs.

### Option 2 — Build from source

```bash
git clone https://github.com/justoeu/ai-taskbar.git
cd ai-taskbar
make app              # host arch only — fast for dev
make app-universal    # arm64 + x86_64 fat binary
open build/AiTaskbar.app
```

Requirements: macOS 13+ (Ventura), Swift 5.10+ (Xcode Command Line Tools is enough — `xcode-select --install`).

### Option 3 — Check for updates from inside the app

Click the gauge icon → ⓘ About → **Procurar atualizações** / **Check for updates**. The button hits `github.com/justoeu/ai-taskbar/releases/latest` directly, compares semver against your installed version, and offers a one-click DMG download that opens in Finder for you to drag to /Applications.

## Setup per provider

The app **reads existing credentials** — you don't need to paste API keys for the OAuth-based ones.

| Provider | Source | Setup |
|---|---|---|
| **Claude** | macOS Keychain entry `Claude Code-credentials` | Run `claude` CLI once. Zero setup. |
| **Codex / ChatGPT** | `~/.codex/auth.json` | Run `codex` CLI once. Zero setup. |
| **OpenRouter** | API key | Add `api_key = "sk-or-v1-..."` to `[openrouter]` in config |
| **Z.AI (GLM)** | API key | Add `api_key = "..."` to `[zai]` in config |
| **Kimi (Moonshot)** | API key | Add `api_key = "sk-..."` to `[kimi]` in config |

> ⚠️ **macOS env vars footgun:** GUI apps launched from Finder do **not** inherit your shell environment. If you set `OPENROUTER_API_KEY=...` in `~/.zshrc`, the menu bar app **won't see it**. Three workarounds:
> 1. **Put the key directly in `config.toml`** (file is `chmod 600`).
> 2. Launch from a terminal: `OPENROUTER_API_KEY=sk-... open /Applications/AiTaskbar.app`.
> 3. Set it globally: `launchctl setenv OPENROUTER_API_KEY "sk-..."` (until reboot).

## What's in this version

### v0.1.0 — initial release

**Core**
- 5 LLM providers — Anthropic Claude, OpenAI Codex/ChatGPT, OpenRouter, Z.AI (GLM), Kimi (Moonshot)
- OAuth auto-refresh for Anthropic + OpenAI using their official `client_id`s
- Per-vendor caches with 60-second TTL and 7-day stale fallback

**UI**
- SwiftUI `MenuBarExtra` with accordion popover (locked providers stay collapsed)
- 24-hour sparkline with dashed threshold lines (warning + critical), current-value annotation, and peak marker
- Color-coded gauge in the menu bar (rotating mode optional)
- Per-model cost breakdown (today / last 7 days side-by-side)
- About panel with version + GitHub Releases update checker

**i18n** — 3 languages out of the box (`en`, `pt-BR`, `es`) with `[ui] language = ...` config override

**Security**
- macOS Keychain reader with single-pass query (1 ACL prompt for single-account, 2 for multi-account)
- `~/.codex/auth.json` write-back with atomic `0o600` chmod **before** rename
- All cache/config files chmod `0o600`, support dir `0o700`
- OpenAI cache strips PII (`user_id`/`account_id`/`email`)
- `KimiConfig.base_url` host allow-listed (SSRF defense)
- TOCTOU symlink refusal on cache dirs
- Optional TLS pinning via TOFU SPKI hashes

**Cost tracking**
- Reads `~/.claude/projects/*/*.jsonl` (Claude Code sessions) — byte prefilter rejects ~73% of lines without JSON parse
- Reads `~/.codex/logs_2.sqlite` via libsqlite3 — regex-based `model=`/`total_usage_tokens=` extraction
- Pricing table for known Anthropic, OpenAI, and Kimi models (prefix matching tolerates date-suffixed variants)
- Per-model breakdown for today **and** last 7 days

**Build / distribution**
- Universal binary (`arm64 + x86_64`) via `make app-universal`
- DMG packaging via `make dmg-universal`
- Developer ID signing + notarization targets ready (`make release`)
- GitHub Actions release workflow (`.github/workflows/release.yml`) auto-builds per tag

**Validation**
- `make validate` runs **143 runtime assertions** + 5-stage gate (build → suite → bundle → smoke launch → permission audit). Replaces XCTest on systems with only Command Line Tools.

## How it works

```
┌─────────────────────────────────────────────────────────────┐
│                  AiTaskbarApp (SwiftUI)                     │
│  ┌────────────────────┐    ┌────────────────────────────┐  │
│  │  MenuBarExtra      │    │  UpdateChecker             │  │
│  │  (gauge icon + %)  │    │  (GitHub Releases)         │  │
│  └─────────┬──────────┘    └────────────────────────────┘  │
│            │                                                │
│  ┌─────────▼──────────┐    ┌────────────────────────────┐  │
│  │  PopoverContentView│    │  AboutView                 │  │
│  │  + VendorSection   │    │  (version + l10n + updates)│  │
│  └─────────┬──────────┘    └────────────────────────────┘  │
└────────────┼────────────────────────────────────────────────┘
             │
┌────────────▼────────────────────────────────────────────────┐
│                  UsageStore (coordinator)                   │
│  Holds 5 × VendorViewModel (per-vendor @ObservableObject).  │
│  Computes maxUtilization aggregate for the menu bar gauge.  │
└────────────┬────────────────────────────────────────────────┘
             │
┌────────────▼────────────────────────────────────────────────┐
│              5 × Provider (UsageProvider impl)              │
│              All use CachedFetch helper:                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 1. Cache check (60s TTL → no network)                │  │
│  │ 2. Credentials read (Keychain / file / env+config)   │  │
│  │ 3. OAuth refresh if needed (shared OAuthRefresher)   │  │
│  │ 4. HTTP request                                      │  │
│  │ 5. Decode wire types (lenient int/float)             │  │
│  │ 6. Persist payload to cache (atomic, 0o600)          │  │
│  │ 7. Fallback to stale cache on any error              │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────┬────────────────────────────────────────────────┘
             │
┌────────────▼────────────────────────────────────────────────┐
│  AiTaskbarCore                                              │
│  Networking (HTTPClient w/ optional pinning) ·              │
│  Cache (DiskCache + AtomicFileWrite) ·                      │
│  Credentials (Keychain, File, EnvOrConfig) ·                │
│  Config (TOMLKit) · Cost (ClaudeSessionScanner +            │
│  CodexLogScanner + PricingTable) ·                          │
│  History (UsageHistoryStore — JSONL append + compact 24h)   │
└─────────────────────────────────────────────────────────────┘
```

The **`RefreshScheduler`** fires every `refresh_interval_seconds` (default 150s = 2.5 min — chosen as a balance between freshness and being polite to the Anthropic usage endpoint, which rate-limits aggressively below ~60s) and triggers `UsageStore.refreshAll()`, which fans out to each `VendorViewModel`. Per-vendor state updates only invalidate that vendor's `VendorSectionView` — no fan-out re-renders.

## Configuration

Lives at `~/Library/Application Support/ai-taskbar/config.toml`. The app auto-creates and tops up missing sections on launch (your edits are preserved). Click **Config** in the popover footer to open it.

Full schema in [`config.example.toml`](config.example.toml). Highlights:

```toml
[ui]
# primary = "anthropic"              # which vendor opens first
# menu_bar_mode = "icon_and_percent"   # icon | icon_and_percent | rotating
# refresh_interval_seconds = 150     # default 150 (2.5m). Floor 15. Common: 60, 150, 300, 600.
# language = "pt-BR"                 # force UI language (en | pt-BR | es)

[thresholds]
warning  = 70                        # green → yellow above this
critical = 90                        # → orange/red above this

[notifications]
enabled   = true
notify_at = [90, 100]                # percent thresholds that trigger a notification
# discreet = true                    # hides vendor name from lock-screen previews

[updates]
# enabled = true
# owner_repo = "justoeu/ai-taskbar"  # GitHub <owner>/<repo>
# include_prereleases = false

[security]
# pin_hosts = ["api.anthropic.com", "chatgpt.com", "openrouter.ai", "api.z.ai", "api.moonshot.ai"]
# pin_audit_only = false

[anthropic]
enabled = true
# keychain_account = "your.short.username"   # pin if you have multiple Claude entries

[openai]
enabled = true
# codex_auth_path = "/Users/you/.codex/auth.json"

[openrouter]
enabled = true
api_key_env = "OPENROUTER_API_KEY"
# api_key = "sk-or-v1-..."

[zai]
enabled = true
api_key_env = "ZAI_API_KEY"
# api_key = "..."
# plan_tier = "lite"                 # lite | pro | max

[kimi]
enabled = true
api_key_env = "MOONSHOT_API_KEY"
# api_key = "sk-..."
# base_url = "https://api.moonshot.ai/v1"   # or https://api.moonshot.cn/v1
```

## Where data lives

| Path | What | Perms |
|---|---|---|
| `~/Library/Application Support/ai-taskbar/config.toml` | Your settings | `0600` |
| `~/Library/Application Support/ai-taskbar/history/<vendor>.jsonl` | 7 days of max-utilization samples (sparkline) | `0600` |
| `~/Library/Application Support/ai-taskbar/pins/<host>.txt` | TLS pin hashes (only if pinning enabled) | `0600` |
| `~/Library/Caches/ai-taskbar/<vendor>/usage.json` | Last cached API response (OpenAI has PII stripped) | `0600` |

The app **never writes outside these locations**. No telemetry, no remote logging.

## Privacy & security

- Anthropic OAuth tokens stay in the **Keychain** — the app reads them, never copies them to disk.
- Codex `~/.codex/auth.json` writes go through atomic tempfile with `0o600` set **before** the rename — no race window where fresh refresh tokens are world-readable.
- Configuration files (`config.toml`) and cache files are `chmod 0600`, support dir `chmod 0700`.
- OpenAI cache strips `user_id`/`account_id`/`email` fields before persisting — only utilization data survives.
- `KimiConfig.base_url` is allow-listed against `api.moonshot.ai`/`api.moonshot.cn` to prevent API-key exfil via attacker-controlled config.
- Optional **TLS pinning** with Trust-On-First-Use SPKI hashes for paranoid setups.
- Hardened-runtime entitlements ready for Developer ID signing (see [`Resources/entitlements.plist`](Resources/entitlements.plist)).
- TOCTOU symlink refusal on cache + support directories.
- All audit findings from a 5-agent code review are tracked and addressed; see `CLAUDE.md` for the policy.

## Build from source

```bash
make app                # debug-quality release build, host arch (fast iteration)
make app-universal      # arm64 + x86_64 fat binary
make icon               # regenerate Resources/AppIcon.icns from Swift drawing script
make dmg                # host-arch DMG
make dmg-universal      # universal DMG
make validate           # 143+ assertion suite + smoke launch + perms audit
make sign-developer     # requires DEVELOPER_ID env var
make notarize           # requires APPLE_ID/APPLE_TEAM_ID/APPLE_PASSWORD
make release            # full pipeline: sign → notarize → staple → DMG
make clean
```

### Customize bundle identifier

```bash
make BUNDLE_ID=com.yourorg.aitaskbar app
```

### Code-signed distribution (optional, requires paid Apple Developer ID)

```bash
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID12345)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="TEAMID12345"
export APPLE_PASSWORD="app-specific-pwd-from-appleid.apple.com"
make release
```

Result: a DMG that opens with **no Gatekeeper warnings** on any macOS 11+ Mac. Without this, you get the one-time warning described in [Install](#install).

## Releasing a new version

```bash
git tag v0.1.0
git push origin v0.1.0
```

The [release workflow](.github/workflows/release.yml) runs on GitHub-hosted macOS runners:
1. Build universal DMG via `make dmg-universal`
2. Verify code signature
3. Run the 143-assertion validation suite
4. Compute SHA256 of the DMG
5. Create a GitHub Release with auto-generated notes + the DMG attached

Pre-releases: tag like `v0.2.0-beta1` — the workflow marks them as pre-release automatically.

## Architecture

```
AiTaskbarApp/             SwiftUI MenuBarExtra + popover + About + UpdateChecker
  ViewModels/             UsageStore (coordinator) + VendorViewModel (per vendor)
  Views/                  VendorSectionView (accordion), Sparkline, MenuBarLabel
  Localization/           L10n.swift + Resources/<lang>.lproj/Localizable.strings
AiTaskbarProviders/       5 providers — all use CachedFetch + OAuthRefresher helpers
AiTaskbarCore/
  Models/                 UsageSnapshot, FetchOutcome, AppError, VendorId
  Networking/             HTTPClient (ephemeral session), PinStore, PinningDelegate
  Cache/                  DiskCache (TTL+stale fallback), AtomicFileWrite
  Credentials/            Keychain, File, EnvOrConfig readers + JSONValue
  Config/                 AppConfig + ConfigLoader (TOMLKit) + flexibleDouble
  Cost/                   ClaudeSessionScanner, CodexLogScanner, PricingTable
  History/                UsageHistoryStore (persistent JSONL + NSLock)
  Util/                   Paths, JWT, Semver, SharedCoders
AiTaskbarValidate/        143+ runtime asserts (replaces XCTest on CLT-only setups)
AiTaskbarTesting/         Fixtures + StubURLProtocol (shared by tests + validate)
Tests/                    XCTest tests (require full Xcode)
```

See [CLAUDE.md](CLAUDE.md) for the architectural deep dive, hard rules, and the checklist for adding a new vendor.

## Roadmap

Likely **v0.2** candidates (no commitments):

- [ ] **Sparkle integration** for real silent updates (once Developer ID code signing is in place)
- [ ] **Global hotkey** to open the popover (`MenuBarExtraAccess`)
- [ ] **OpenAI Platform API** (`sk-...` key) for hard-budget tracking — separate from ChatGPT/Codex
- [ ] **Per-window historical chart** in a separate dashboard window
- [ ] **Cost forecast** ("at current rate, you'll hit weekly limit at 3pm")
- [ ] **Export usage data** as CSV / JSON
- [ ] More languages (French, German, Japanese) — translations welcome via PR

## Contributing

1. Run `make validate` before opening a PR — the gate has to be green.
2. New vendor → follow the checklist in [CLAUDE.md](CLAUDE.md) ("Adding a new LLM vendor").
3. New strings → add to all three `.lproj/Localizable.strings` files.
4. Architectural changes → update [CLAUDE.md](CLAUDE.md) at the same time.
5. The `AiTaskbarValidate` target is the day-to-day test cover; XCTest in `Tests/` is for the day full Xcode is the developer tool of choice.

## License

MIT — see [LICENSE](LICENSE). Inspired by [`akitaonrails/ai-usagebar`](https://github.com/akitaonrails/ai-usagebar) (Linux/Waybar).
