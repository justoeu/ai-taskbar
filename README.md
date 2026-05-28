# AI Taskbar

> Native macOS menu-bar app that tracks LLM usage across **Claude, OpenAI Codex/ChatGPT, OpenRouter, Z.AI (GLM), and Kimi (Moonshot)** — at a glance.

Inspired by [akitaonrails/ai-usagebar](https://github.com/akitaonrails/ai-usagebar) (Linux/Waybar). This is a macOS-native port: SwiftUI `MenuBarExtra`, Keychain integration, no external CLI dependencies.

![Menu bar gauge + accordion popover with per-provider usage windows, sparkline history, daily cost.](docs/screenshot.png)

## Install

### Option 1 — Download the DMG (recommended)

1. Grab the latest `ai-taskbar-X.Y.Z.dmg` from [Releases](../../releases).
2. Open the DMG and drag **AI Taskbar.app** to **/Applications**.
3. First launch — Gatekeeper will warn it's from an unidentified developer. Either:
   - **Right-click `AiTaskbar.app` → Open**, then click Open in the dialog.
   - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/AiTaskbar.app`

   This is a one-time step; subsequent launches are silent.
4. Click the gauge icon that appears in your menu bar.

The DMG ships a **universal binary** — works on Apple Silicon and Intel Macs.

### Option 2 — Build from source

```bash
git clone https://github.com/<your-fork>/ai-taskbar.git
cd ai-taskbar
make app          # host-arch only, faster for dev
make app-universal  # arm64 + x86_64 fat binary
open build/AiTaskbar.app
```

Requirements: macOS 13+, Swift 5.10+ (ships with Xcode Command Line Tools — `xcode-select --install`).

## What it shows

For each enabled provider, the popover renders one card with:

- **Plan label** (e.g. "Claude Max 5x", "ChatGPT Plus", "GLM Lite")
- **Per-window utilization** — Session 5h, Weekly 7d, Opus 7d (Anthropic); Primary/Secondary (OpenAI); Balance (OpenRouter/Kimi); Session/Weekly/MCP (Z.AI)
- **Progress bar** + **% number**, color-coded by threshold (green → yellow → red)
- **Reset countdown** ("resets 4 hrs, 12 min")
- **24-hour sparkline** of max-utilization history
- **Estimated daily cost** for Anthropic and OpenAI (read from local CLI logs)
- **Click the LLM name** → opens that vendor's official dashboard
- **Lock-icon** + "no credentials" state when a provider isn't configured

The menu bar itself shows the **highest utilization across all enabled providers** as a colored gauge + (optionally) percent.

## Setup per provider

The app **reads existing credentials** — you don't have to paste API keys for the OAuth-based ones.

### Claude (Anthropic) — zero setup

Reads OAuth token from the macOS Keychain entry `Claude Code-credentials`. If you've ever run the `claude` CLI, you already have this. Otherwise: `brew install --cask claude` and sign in once.

### Codex / ChatGPT (OpenAI) — zero setup

Reads `~/.codex/auth.json` (created by the `codex` CLI when you sign in).

### OpenRouter — API key

```bash
# Edit ~/Library/Application Support/ai-taskbar/config.toml
[openrouter]
enabled = true
api_key = "sk-or-v1-..."
```

Or export `OPENROUTER_API_KEY` before launching the app (note: GUI launches from Finder don't inherit shell env — see "About env vars" below).

### Z.AI (GLM) — API key

```toml
[zai]
enabled = true
api_key = "..."
```

### Kimi (Moonshot) — API key

```toml
[kimi]
enabled = true
api_key = "sk-..."
# base_url = "https://api.moonshot.cn/v1"   # only if you're in China region
```

## Configuration

Live at `~/Library/Application Support/ai-taskbar/config.toml` (auto-created on first launch with sensible defaults). Click the **Config** button in the popover footer to open it.

```toml
[ui]
# primary = "anthropic"             # which tab opens first
# menu_bar_mode = "icon_and_percent"  # icon | icon_and_percent | rotating
# refresh_interval_seconds = 60     # min 15

[thresholds]
warning  = 70    # green → yellow above this
critical = 90    # → orange/red

[notifications]
enabled   = true
notify_at = [90, 100]
# discreet = true   # hides vendor name from notification title (lock-screen friendly)

[security]
# pin_hosts = ["api.anthropic.com", "chatgpt.com", "openrouter.ai", "api.z.ai", "api.moonshot.ai"]
# pin_audit_only = false   # set true to log mismatches without blocking
```

Full schema in [`config.example.toml`](config.example.toml).

### About env vars on macOS

GUI apps launched from Finder do **not** inherit your shell environment (no `~/.zshrc`). If you set `OPENROUTER_API_KEY` in your terminal, the menu bar app won't see it. Three options:

1. **Put the key directly in `config.toml`** (simplest, file is `chmod 600`).
2. Launch from a terminal: `OPENROUTER_API_KEY=sk-... open /Applications/AiTaskbar.app`.
3. Set the var globally via `launchctl setenv OPENROUTER_API_KEY "sk-..."` (survives until reboot).

## Where data lives

| Path | What |
|---|---|
| `~/Library/Application Support/ai-taskbar/config.toml` | Your settings, `chmod 600` |
| `~/Library/Application Support/ai-taskbar/history/<vendor>.jsonl` | 7 days of per-vendor max-utilization samples (drives the sparkline) |
| `~/Library/Application Support/ai-taskbar/pins/<host>.txt` | TLS pin hashes (only if `pin_hosts` is configured) |
| `~/Library/Caches/ai-taskbar/<vendor>/usage.json` | Last cached API response, `chmod 600`. **OpenAI cache has PII fields (`user_id`, `account_id`, `email`) stripped** before persisting. |

The app **never** writes outside these locations. **No telemetry**, no remote logging, no auto-update.

## Privacy & security posture

- Configuration files are `chmod 0600` (user-only).
- `~/Library/Application Support/ai-taskbar/` is `chmod 0700`.
- Anthropic OAuth tokens stay in the Keychain — the app reads them but never copies them to disk.
- Codex `~/.codex/auth.json` writes (on token refresh) go through atomic tempfile with `0o600` set **before** the rename — no race window.
- Sensitive fields stripped from cached OpenAI responses.
- Optional TLS pinning with Trust-On-First-Use SPKI hashes.
- No code injection: hardened-runtime entitlements ready for Developer ID signing (`Resources/entitlements.plist`).

## Build options

```bash
make app              # debug-quality release build, host arch (fast)
make app-universal    # arm64 + x86_64 fat binary (slower, ships everywhere)
make dmg              # host-arch DMG
make dmg-universal    # universal DMG
make validate         # 128+ assertion suite + smoke launch + perms audit
make clean
```

### Customize bundle identifier when forking

```bash
make BUNDLE_ID=com.myorg.aitaskbar app
```

Default is `dev.aitaskbar.app` — generic enough that the upstream repo doesn't bake anyone's namespace.

### Code-signed distribution (optional, requires paid Apple Developer ID)

```bash
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID12345)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="TEAMID12345"
export APPLE_PASSWORD="app-specific-pwd-from-appleid.apple.com"
make release         # sign + bundle DMG + notarize + staple
```

Result: a DMG that opens with no Gatekeeper warnings on any macOS 11+ machine. Without this you get Gatekeeper warnings on first launch (one-time, see Install above).

## Releasing a new version

1. `git tag v0.1.0 && git push origin v0.1.0`
2. The [release workflow](.github/workflows/release.yml) runs on GitHub-hosted macOS runners, builds a universal DMG, computes SHA256, and attaches everything to the Release.
3. Pre-releases: tag like `v0.2.0-beta1` — workflow marks them as pre-release automatically.

## Architecture

```
AiTaskbarApp/         — SwiftUI MenuBarExtra + popover + About panel
  ViewModels/         — UsageStore (coordinator) + VendorViewModel (per vendor)
  Views/              — VendorSectionView (accordion), Sparkline, Menu bar label
AiTaskbarProviders/   — 5 providers, all using CachedFetch + OAuthRefresher
AiTaskbarCore/        — HTTP, Cache, Credentials, Config, Cost, History, Util
AiTaskbarValidate/    — 128+ runtime assertions (replaces XCTest on CLT-only setups)
```

See [CLAUDE.md](CLAUDE.md) for the architectural deep dive and per-vendor checklist.

## License

MIT — see [LICENSE](LICENSE).
