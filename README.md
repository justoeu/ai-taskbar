# AI Taskbar

<p align="center">
  <img src="Resources/icon_preview.png" alt="AI Taskbar icon" width="128" height="128"/>
</p>

<p align="center">
  <b>Native macOS menu-bar tracker for LLM usage across 8 providers.</b><br/>
  Anthropic Claude · OpenAI Codex/ChatGPT · OpenRouter · Z.AI (GLM) · Kimi (Moonshot) · Gemini · DeepSeek · xAI (Grok)
</p>

<p align="center">
  <a href="https://github.com/justoeu/ai-taskbar/releases"><img src="https://img.shields.io/github/v/release/justoeu/ai-taskbar?include_prereleases&label=release&style=flat-square" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/arch-universal-purple?style=flat-square" alt="Universal binary">
  <img src="https://img.shields.io/badge/swift-6.2%2B-orange?style=flat-square" alt="Swift 6.2+">
</p>

---

## What you get

A gauge icon in your menu bar showing the **highest utilization** across your LLM providers. It reflects only the **expanded (open) cards** in the popover — collapse a provider's card to drop it out of the gauge, so you can focus the number on the subscriptions you actually care about. Click it for a per-provider breakdown:

- **Plan label** ("Claude Max 20x", "ChatGPT Plus", "GLM Lite")
- **Per-window utilization** with color thresholds (green → yellow → red) — for Claude this includes the 5-hour session, 7-day weekly, any **per-model weekly windows** (e.g. Fable), and a **usage-credits** meter (shown with the money spent/limit, e.g. `R$556.68 / R$600.00`). Model windows are parsed generically from the API's `limits[]`, so a newly-launched model appears without an app update.
- **Reset countdown** ("resets 4 hrs, 12 min"; once the reset passes it shows "reset due — awaiting auto-refresh…" instead of counting back up)
- **24-hour sparkline** with dashed threshold lines, current value, and peak marker
- **Daily + 7-day cost estimates** computed locally from your CLI logs
- **Per-model breakdown** ("opus-4-7 $1850 / haiku-4-5 $245")
- **opencode usage attributed to the vendor that billed it** — opencode is a client, not a provider, so its traffic shows up under OpenAI or xAI with its own line. Subscription traffic (ChatGPT-plan models) shows tokens rather than dollars, because no money moves; pay-per-token traffic shows the cost opencode itself recorded, as a breakdown of the total the vendor's API already reports — never added on top of it
- **Click the card header** (chevron + name + empty space) to expand/collapse; dashboard / reorder / refresh stay on the trailing buttons
- **Reorder cards** with ↑ / ↓ on each header (order saved on this Mac)
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
- [Contributing](#contributing)
- [License](#license)

## Install

### Option 1 — Download the DMG (recommended)

1. Download the DMG matching your Mac from [Releases](https://github.com/justoeu/ai-taskbar/releases):
   `ai-taskbar-X.Y.Z-arm64.dmg` (Apple Silicon, smaller) or the universal
   `ai-taskbar-X.Y.Z.dmg` (Intel + Apple Silicon).
2. Open the DMG and drag **AI Taskbar.app** to **/Applications**.
3. **First launch** — release DMGs are Developer ID-signed and notarized by
   Apple, so they open with no Gatekeeper warning. (Only ad-hoc DMGs from
   old releases or local `make dmg` builds warn; bypass with right-click →
   Open, or `xattr -dr com.apple.quarantine /Applications/AiTaskbar.app`.)

### Option 2 — Build from source

```bash
git clone https://github.com/justoeu/ai-taskbar.git
cd ai-taskbar
make app              # host arch only — fast for dev
make app-universal    # arm64 + x86_64 fat binary
open build/AiTaskbar.app
```

The app runs on macOS 13+ (Ventura). Building the app requires Swift 6.2+; Command Line Tools is enough. Running the tests requires **full Xcode** and the macOS version supported by its bundled Testing framework (validated with Xcode's Swift 6.3.3). CLT 6.3.2 cannot reliably locate its bundled Testing framework/runtime.

### Option 3 — Check for updates from inside the app

Click the gauge icon → ⓘ About → **Procurar atualizações** / **Check for updates**. The button hits `github.com/justoeu/ai-taskbar/releases/latest` directly, compares semver against your installed version, and offers a one-click DMG download that opens in Finder for you to drag to /Applications.

## Setup per provider

The app **reads existing credentials** — you don't need to paste API keys for the OAuth-based ones.

| Provider | Source | Setup |
|---|---|---|
| **Claude** | macOS Keychain entry `Claude Code-credentials` | Run `claude auth login`; use the in-app Keychain authorization when requested |
| **Codex / ChatGPT** | `~/.codex/auth.json` | Run `codex login`. Zero setup after the CLI creates the file. |
| **OpenRouter** | API key | Add `api_key = "sk-or-v1-..."` to `[openrouter]` in config |
| **Z.AI (GLM)** | API key | Add `api_key = "..."` to `[zai]` in config |
| **Kimi (Moonshot)** | API key | Add `api_key = "sk-..."` to `[kimi]` in config |
| **DeepSeek** | API key | Add `api_key = "sk-..."` to `[deepseek]` in config |
| **Gemini** | API key | Add `api_key = "AIza..."` to `[gemini]` — **heartbeat only** (see below) |
| **xAI (Grok)** | Management key + team ID | Create a **management** key at [console.x.ai](https://console.x.ai) → Settings → Management Keys (not the inference API key); copy the team UUID from Team settings; set `api_key` + `team_id` under `[xai]` |

> ⚠️ **macOS env vars footgun:** GUI apps launched from Finder do **not** inherit your shell environment. If you set `OPENROUTER_API_KEY=...` in `~/.zshrc`, the menu bar app **won't see it**. Three workarounds:
> 1. **Put the key directly in `config.toml`** (file is `chmod 600`).
> 2. Launch from a terminal: `OPENROUTER_API_KEY=sk-... open /Applications/AiTaskbar.app`.
> 3. Set it globally: `launchctl setenv OPENROUTER_API_KEY "sk-..."` (until reboot).

### OAuth recovery — **Authorize** vs **Re-login**

These buttons solve different failures and are intentionally kept separate:

| Failure | What the card shows | What the button does |
|---|---|---|
| macOS blocks AI Taskbar from silently reading Claude Code's Keychain item (`errSecInteractionNotAllowed` / `errSecAuthFailed`) | **Authorize** | Requests a native read of the exact selected item; macOS owns the authorization dialog and ACL updates. Success requires a verified silent read. The password never enters the app. |
| Claude or ChatGPT rejects an existing OAuth access token with HTTP 401 | **Re-login** | Delegates login to the CLI that owns the shared credential: `claude auth login` for Claude or `codex login` for Codex/ChatGPT. The CLI opens the browser and writes the renewed credential. |

The 401 banner appears inside the expanded provider card. AI Taskbar does not
rotate a shared refresh token in its default read-only mode. After **Re-login**
starts, it automatically retries the provider after 30 and 75 seconds; changes
to Codex's `~/.codex/auth.json` also trigger an immediate debounced refresh. If
the command cannot be launched, the card displays it so it can be copied and
run manually. When cached usage exists, it remains visible as stale data while
authentication is being repaired.

An API-key provider does not get a **Re-login** button for 401 responses: its
recovery is to replace the invalid key in `config.toml` or the configured
environment variable.

### Claude Code on macOS — Keychain access

Claude Code stores its OAuth token in the macOS Keychain, not in a user-readable
file like Codex's `~/.codex/auth.json`. The item is created for Claude Code's
own signing identity. Scheduled refreshes never display a surprise password
dialog: when macOS blocks a silent read, click **Authorize** in the Claude card.
That user-initiated action requests a read of the exact selected item, letting
macOS authorize the stable signed AI Taskbar identity through its native dialog; choose **Always Allow** if offered. The app never receives or
stores the Keychain password and reports success only after verifying a
silent read. Subsequent launches can reuse that authorization while Claude
Code preserves the item and its access controls. AI Taskbar never copies the
token to disk.

An `errSecAuthFailed` (-25293) during authorization does **not** establish that
the password is wrong. Earlier builds attempted to edit the protected partition
list directly with `SecKeychainItemSetAccess`, whose prompt credentials cannot
authorize that operation. An ACL-only commit can also succeed without making a foreign item readable.
The app now requests native read authorization and lets securityd manage that
list, without a Terminal command or manual ACL replacement. See Apple's implementation of
[ACL editing](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/acls.cpp)
and [native authorization](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/acl_keychain.cpp).

If several account-bearing Claude entries exist and none has previously been
resolved, authorization stops without changing any ACL instead of guessing
which credential is active. Set `keychain_account` in Anthropic settings and
click **Authorize** again.

If native authorization cannot persist, the card reports verification failure.
Managed Keychain policies may require help from the device administrator.
No Terminal command or Keychain password collection is part of onboarding.

**Why the prompt used to come back after every rebuild.** macOS records the
*code signature* of the app you authorized, not its name. An ad-hoc-signed
build (`make dmg`, or `make app` on a machine without a Developer ID
certificate) has a per-build `cdhash` identity, so every rebuild or update is a
"new app" to the Keychain and the banner reappears. A Developer ID build has a
stable identity (`identifier "dev.aitaskbar.app"` + team ID) and is authorized
once for all future versions. Run the notarized `/Applications/AiTaskbar.app`
for day-to-day use.

**Read-only fallback through `/usr/bin/security`.** When the direct read
fast-fails on the ACL, AI Taskbar now asks Apple's `security` tool for the
exact item (`find-generic-password -s <service> -a <account> -w`). Claude Code
writes the item with that same tool, so it is always on the item's trusted-app
list; the read succeeds silently regardless of how AI Taskbar itself is signed,
and the card shows usage instead of the Authorize banner. The child runs under a
5 s budget (a hung tool means securityd raised a dialog on its behalf; the
child is killed, which dismisses it, and the fallback pauses for an hour — five
minutes after an ordinary failure), is skipped while the keychain is locked
(that would be the unlock dialog), and is never used for writes; while a
credential comes from the fallback the app also never rotates the OAuth token,
even with `manage_oauth_refresh = true`. Authorize still works and restores the direct path.

### Claude `429 rate_limit_error`

When the warning tooltip contains Anthropic's JSON with
`"type": "rate_limit_error"`, the server really returned HTTP 429; it is not a
snapshot-decoding error. AI Taskbar keeps showing the last cached snapshot and
applies a per-provider exponential cooldown of 5, 10, 20, 40, then 60 minutes.
Other providers keep their normal schedule, and manual refresh cannot bypass
the affected provider's active cooldown. The existing scheduler also adds its
short 60-second global settling delay after a 429 cycle. If 429s persist, you
can still increase `[ui] refresh_interval_seconds` from `300` to `900` or
`1800`. The subscription usage endpoint is undocumented and Anthropic publishes
no polling quota for it, so the app cannot calculate an exact retry time unless
the response supplies one.

### OpenAI / Codex — earned rate-limit resets

When a current, healthy usage snapshot reports an active window **above 90%**
and a positive earned-reset count, the OpenAI card offers **Use reset**. Clicking
checks availability again; a separate confirmation identifies the account and
explains that one earned reset will be consumed. Nothing runs automatically.

This requires a compatible official, OpenAI-signed Codex CLI (integration reference:
0.153.4). Older schemas, missing account identity or unavailable resets fail closed.
The external-token app-server API is experimental. AI Taskbar does not buy credits,
rotate the shared refresh token, or change the CLI's authentication file.

If a response is lost, **Retry same attempt** keeps the original idempotency key,
including across app restarts. A private `openai-reset-attempt.json` journal and
cross-process lock prevent separate local app instances from replacing a pending
attempt. See the [implementation SDD](docs/SDD-native-authorization-and-openai-reset.md)
for the protocol, security boundaries, tests and manual acceptance checks.

### xAI (Grok) — API team billing, not SuperGrok consumer usage

The xAI card reads the **Management API** (`management-api.x.ai`): prepaid credit balance and current-cycle postpaid spend vs soft spending limit. That is **developer/team API billing**, not the weekly SuperGrok / grok.com consumer quota UI. Inference keys on `api.x.ai` cannot read billing; a separate management key + `team_id` are required. SuperGrok subscription limits have no public usage API today.

### Google Gemini — limited; no usable usage/quota API

Gemini ships as a provider but it can only do an **API-key heartbeat**: with a Google AI Studio key it validates the key and reports the model count (`GET /v1beta/models`). **It cannot show usage or cost**, because none of Google's surfaces expose a readable consumption API for the products people actually have:

| Surface | Usage API? |
|---|---|
| **Gemini app subscription** (Plus / AI Pro / Ultra, `gemini.google.com/usage`) | ❌ No public API — the 5-hour/weekly limits live only in the app UI. |
| **Developer API** (AI Studio key / Vertex via a GCP project) | ✅ Cloud Monitoring (`serviceruntime.googleapis.com/quota/...`) — but it measures *GCP-project API requests*, needs a Cloud project + monitoring scope, and is **not** your consumer subscription. |
| **Gemini Code Assist** (the `gemini-cli`, `~/.gemini/oauth_creds.json`) | ⚠️ Undocumented `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` — per-model `remainingFraction`. **Being retired for individuals on 2026-06-18** in favor of Antigravity, and it's the free coding tier, *separate from* a paid Gemini app subscription. |
| **Antigravity CLI** (`agy`) | ❌ No `usage` subcommand; the app stores auth as encrypted Electron cookies + Keychain safeStorage — no readable token, no usage endpoint. |

**Bottom line:** there is no durable, official way to read your Gemini *subscription* usage today. If you don't have (or don't want) a Gemini API key, set `[gemini] enabled = false` in `config.toml` to hide the "no credentials" row. This will be revisited if Google ships a real consumer usage API (OAuth, not web cookies).

## What's in this version

### v0.12 — xAI billing, reorderable cards, full-header expand

- **Eighth provider — xAI (Grok) via Management API.** Prepaid balance + monthly spend vs soft limit from `management-api.x.ai` (management key + team ID). Inference host `api.x.ai` is rejected by the host allow-list. Settings UI labels the fields as management key / team ID with localized help. Dashboard link points at the console usage page.
- **Reorder vendor cards** with ↑ / ↓ on each card header. Order is stored in `UserDefaults` (`vendor_order`) on this Mac; rotating menu-bar mode follows the same order. (Drag-and-drop is unreliable inside `MenuBarExtra` windows on macOS, so buttons are the supported path.)
- **Click anywhere on the leading header** (chevron + name + plan + flexible space) to expand/collapse. Dashboard, reorder, and refresh remain separate trailing controls.

### v0.2 — Gemini, calmer cadence, honest countdown, no more Keychain prompts

- **Sixth provider — Google Gemini.** Uses `GET /v1beta/models` as an authenticated heartbeat (Generative Language API has no public quota REST endpoint). Auth via `x-goog-api-key` header, never `?key=` query string. Host allow-listed to `generativelanguage.googleapis.com`. `GeminiConfig.validate` is strict on the API-version segment — `base_url` must be exactly `/v1`, `/v1beta`, or `/v1alpha` (or a sub-path of one). A typo like `/v1xxx` is rejected at config-load with an NSLog warning, instead of producing a silent 404 at first fetch. A future Google rename (`models` → `availableModels`) lands as `AppError.schema` + red row, not as a silently green "no models visible".
- **Default refresh cadence raised from 150 s → 300 s (5 min).** A conservative starting point for undocumented usage endpoints; individual vendors can still impose longer or account-wide 429 windows. Floor is still 15 s; override via `[ui] refresh_interval_seconds = …`.
- **Forward countdown in the popover header.** "Próx. em 4:59" replaces the old "atualizado há …" — anchored on `UsageStore.lastScheduledTickAt`, which is stamped by `RefreshScheduler.markScheduledTick()` immediately before every cycle. When the scheduler is in the 60 s post-429 back-off the label switches to "Aguardando rate-limit…"; while a fetch is in flight it says "Atualizando…". Pre-computed `@Published` aggregates (`isAnyVendorLoading`, `hasRateLimitedVendor`) keep the per-second TimelineView reading flat properties instead of re-scanning the vendor array; localized strings are memoized at type init.
- **Rate-limit back-off.** When any vendor's most recent refresh ended in HTTP 429, `RefreshScheduler` adds `rateLimitBackoff` (60 s) to the next sleep. Stays applied while at least one vendor keeps 429-ing; clears automatically when responses go green. `UsageStore.hasRateLimitedVendor` detects both `.failed(429, _)` AND stale-`.ok` outcomes whose cached `lastError.status == 429` (CachedFetch hides single 429s as `.ok(stale)` whenever any payload is cached).
- **Per-provider exponential cooldown.** A vendor that keeps returning 429 is skipped for 5, 10, 20, 40, then at most 60 minutes. Manual refresh respects the same deadline, so repeated clicks cannot turn a temporary throttle into a longer one; providers that are not rate-limited continue refreshing.
- **Cache TTL automatically derived from the cadence** — `max(15, refresh_interval_seconds − 5)`. Popover opens between scheduled refreshes still serve from cache, but the scheduled tick at T=interval always finds an expired entry (`age ≈ interval > ttl`) and goes straight to the network without needing `forceRefresh: true`. The 5-second margin absorbs Task.sleep jitter.
- **Keychain write no longer triggers the macOS password prompt.** `KeychainCredentialReader.writeBack` passes `kSecUseAuthenticationUIFail` (the deprecated key — the modern `LAContext.interactionNotAllowed` doesn't work for plain generic-password items without a `SecAccessControl`) and treats `errSecInteractionNotAllowed` as best-effort: logs a prompt to use the in-app Authorize button and returns. The renewed credentials are mirrored to an in-memory `_pendingUpdate`; the next `read()` reconciles against the on-disk copy by `expiresAtMs` (so an external rotation via Claude Code CLI wins automatically when it lands). Menu-bar app (LSUIElement) no longer freezes behind an invisible SecurityAgent dialog after every `make app` rebuild.

### v0.1.0 — initial release

**Core**
- 5 LLM providers — Anthropic Claude, OpenAI Codex/ChatGPT, OpenRouter, Z.AI (GLM), Kimi (Moonshot)
- OAuth auto-refresh for Anthropic + OpenAI using their official `client_id`s
- Per-vendor caches with 150-second TTL (matched to the v0.1 default refresh interval) and 7-day stale fallback

**UI**
- SwiftUI `MenuBarExtra` with accordion popover (locked providers stay collapsed)
- 24-hour sparkline with dashed threshold lines (warning + critical), current-value annotation, and peak marker
- Color-coded gauge in the menu bar (rotating mode optional)
- Per-model cost breakdown (today / last 7 days side-by-side)
- About panel with version + GitHub Releases update checker; on Developer ID-signed builds it also credits the developer, read live from the binary's signing certificate (ad-hoc builds omit the line)

**i18n** — 3 languages out of the box (`en`, `pt-BR`, `es`) with `[ui] language = ...` config override

**Security**
- macOS Keychain reader with single-pass query for the common single-account case; auto-discovers the live entry via freshest-token-wins whenever entries are readable, and requires `keychain_account` before changing an ambiguous all-blocked multi-account ACL
- `~/.codex/auth.json` write-back with atomic `0o600` chmod **before** rename
- All cache/config files chmod `0o600`, support dir `0o700`
- OpenAI cache strips PII (`user_id`/`account_id`/`email`)
- `KimiConfig.base_url` host allow-listed (SSRF defense)
- TOCTOU symlink refusal on cache dirs
- Optional TLS pinning via TOFU SPKI hashes

**Cost tracking**
- Reads `~/.claude/projects/*/*.jsonl` (Claude Code sessions) — byte prefilter rejects ~78% of lines without JSON parse (measured on the largest local transcript: 22.541 of 28.870 lines; the ratio depends on how tool-heavy your sessions are)
- Reads `~/.codex/sessions/**/rollout-*.jsonl` (Codex CLI transcripts) — per-turn `token_count` events give a real input/output/cached split, attributed to the model named by the enclosing `turn_context`
- Falls back to `~/.codex/logs_2.sqlite` (regex `model=`/`total_usage_tokens=`) only when the rollout scan prices nothing — current Codex builds stopped emitting that field, and the two sources describe the same turns, so they're never summed
- Pricing table for Anthropic + OpenAI models, used by the local Claude/Codex scanners (longest-prefix matching tolerates date- and deployment-suffixed variants such as `claude-opus-5-thinking` or `gpt-5.6-sol`). Gemini/Kimi/OpenRouter/Z.AI surface cost or balance straight from each vendor's API, so they don't use this table.
- Per-model breakdown for today **and** last 7 days

**Build / distribution**
- Universal binary (`arm64 + x86_64`) via `make app-universal`
- DMG packaging via `make dmg-universal`
- Developer ID signing + notarization targets ready (`make release`)
- GitHub Actions release workflow (`.github/workflows/release.yml`) auto-builds per tag

**Validation**
- `make validate` runs **160 runtime assertions** + 6-stage gate (build → validate runner → swift-test + coverage → bundle → smoke launch → permission audit). Coverage floor on `AiTaskbarCore` + `AiTaskbarProviders` enforced at ≥ 90%.

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
│  Holds N × VendorViewModel (per-vendor @ObservableObject).  │
│  maxUtilization = max over EXPANDED cards → menu bar gauge. │
│  sortedVendors = user order (↑/↓) or configured-first.      │
└────────────┬────────────────────────────────────────────────┘
             │
┌────────────▼────────────────────────────────────────────────┐
│              N × Provider (UsageProvider impl)              │
│              All use CachedFetch helper:                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 1. Cache check (300s TTL → no network)               │  │
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
│  CodexSessionScanner/CodexCost + PricingTable) ·            │
│  History (UsageHistoryStore — JSONL append + compact 24h)   │
└─────────────────────────────────────────────────────────────┘
```

The **`RefreshScheduler`** fires every `refresh_interval_seconds` (default 300s = 5 min — chosen as a balance between freshness and being polite to the Anthropic / Z.AI / Codex usage endpoints, which rate-limit aggressively below ~60s) and triggers `UsageStore.refreshAll()`, which fans out to each `VendorViewModel`. Per-vendor state updates only invalidate that vendor's `VendorSectionView` — no fan-out re-renders.

If any vendor's last refresh ended in HTTP 429, the scheduler adds **`RefreshScheduler.rateLimitBackoff` = 60 s** to the next sleep. The back-off is read via `UsageStore.hasRateLimitedVendor` between cycles and stays applied for as long as at least one vendor keeps returning 429 — once they clear, the cadence drops back to the configured interval automatically. During the back-off the popover countdown shows "Aguardando rate-limit…" (anchored on `UsageStore.isInRateLimitBackoff`) so the header never silently freezes at 0:00. Independently, each `VendorViewModel` tracks consecutive 429s and refuses new network work until its own 5/10/20/40/60-minute cooldown expires; this keeps a throttled provider from blocking normal refreshes for the others.

The per-vendor `DiskCache` TTL is wired to `max(15, refresh_interval_seconds − 5)` in `AppEnvironment`. The 5 s margin means a scheduled tick at T=interval always sees an expired cache (`age ≈ interval > ttl`), so the scheduler doesn't need `forceRefresh: true` to defeat the cache. Popover opens between scheduled refreshes still serve from cache.

## Configuration

Lives at `~/Library/Application Support/ai-taskbar/config.toml`. The app auto-creates and tops up missing sections on launch (your edits are preserved). Click **Config** in the popover footer to open it.

Full schema in [`config.example.toml`](config.example.toml). Highlights:

```toml
[ui]
# primary = "anthropic"              # which vendor opens first
# menu_bar_mode = "icon_and_percent"   # icon | icon_and_percent | rotating
# refresh_interval_seconds = 300     # default 300 (5m). Floor 15. Common: 60, 150, 300, 600.
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
# pin_hosts = ["api.anthropic.com", "chatgpt.com", "openrouter.ai", "api.z.ai", "api.moonshot.ai", "api.deepseek.com", "management-api.x.ai"]
# pin_audit_only = false

[anthropic]
enabled = true
# keychain_account = "your.short.username"   # pin if you have multiple Claude entries
# manage_oauth_refresh = false   # default false: read-only, lets Claude Code own token renewal

[openai]
enabled = true
# codex_auth_path = "/Users/you/.codex/auth.json"
# manage_oauth_refresh = false   # default false: read-only, lets the Codex CLI own token renewal

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

[gemini]
enabled = true
api_key_env = "GEMINI_API_KEY"
# api_key = "AIza..."        # heartbeat only — no usage/quota API

[deepseek]
enabled = true
api_key_env = "DEEPSEEK_API_KEY"
# api_key = "sk-..."
# base_url = "https://api.deepseek.com"

[xai]
enabled = true
api_key_env = "XAI_MANAGEMENT_KEY"
# api_key = "xai-..."        # management key (NOT the inference API key)
# team_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
# base_url = "https://management-api.x.ai"
```

## Where data lives

| Path | What | Perms |
|---|---|---|
| `~/Library/Application Support/ai-taskbar/config.toml` | Your settings | `0600` |
| `~/Library/Application Support/ai-taskbar/history/<vendor>.jsonl` | 7 days of max-utilization samples (sparkline) | `0600` |
| `~/Library/Application Support/ai-taskbar/pins/<host>.txt` | TLS pin hashes (only if pinning enabled) | `0600` |
| `~/Library/Caches/ai-taskbar/<vendor>/usage.json` | Last cached API response (OpenAI has PII stripped) | `0600` |

The app never writes credential payloads outside these locations. The explicit
Claude **Authorize** action normally updates only access-control metadata on the
existing `Claude Code-credentials` Login Keychain item. When the opt-in
`manage_oauth_refresh = true` mode already holds a newer rotated token whose
write was ACL-blocked, authorization also reconciles that pending value back to
the same item. No telemetry, no remote logging.

## Privacy & security

- Anthropic OAuth tokens stay in the **Keychain** — the app reads them, never copies them to disk.
- **The OAuth providers are read-only by default** (`[anthropic] manage_oauth_refresh = false` and `[openai] manage_oauth_refresh = false`). A usage monitor shares the `Claude Code-credentials` Keychain item with the Claude Code CLI and `~/.codex/auth.json` with the Codex CLI, and both vendors rotate the refresh token on every exchange — so refreshing it here would invalidate the token other running CLI sessions hold (forcing "please re-login"), and the Anthropic write-back also trips a Keychain ACL prompt on ad-hoc builds. In read-only mode the app uses whatever token the CLI maintains and lets the CLI own renewal; if the token is briefly expired the last cached snapshot is shown until the CLI refreshes (on a cold cache with no prior snapshot the vendor tile shows the error until renewal). Set `manage_oauth_refresh = true` for a vendor only if you run AI Taskbar standalone without that CLI.
- Keychain reads **and** writes run under `KeychainPromptSuppressor` (`SecKeychainSetUserInteractionAllowed(false)` around every SecItem call) **in addition to** `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`. The UIFail hint alone only silences the trusted-app Allow/Deny confirmation — the partition-list **password** dialog ignores it and used to pop on every scheduled refresh from a binary the ACL didn't recognize. With both in place, a blocked binary fast-fails (`errSecInteractionNotAllowed` / `errSecAuthFailed`) instead of prompting; the renewed access_token is kept in memory and persistence retries on the next OAuth cycle. The log directs the user to the in-app Authorize button.
- When a scheduled read is blocked, the Claude card shows **Authorize**. Its sole interactive read targets one exact item. macOS owns consent; a silent same-item probe is mandatory. The reader binds subsequent reads and opt-in writes to that persistent reference, and never carries pending tokens onto a different or recreated credential.
- `make app` signs local builds with your **Developer ID Application** identity when the login keychain has one, so one Authorize covers subsequent signed rebuilds. The bundle assembly can fall back to ad-hoc signing, but durable authorization fails closed there because an ad-hoc identity cannot safely remain trusted across builds.
- Codex `~/.codex/auth.json` writes go through atomic tempfile with `0o600` set **before** the rename — no race window where fresh refresh tokens are world-readable.
- Configuration files (`config.toml`) and cache files are `chmod 0600`, support dir `chmod 0700`.
- OpenAI cache strips `user_id`/`account_id`/`email` fields before persisting — only utilization data survives.
- `KimiConfig.base_url` is allow-listed against `api.moonshot.ai`/`api.moonshot.cn` to prevent API-key exfil via attacker-controlled config.
- `DeepSeekConfig.base_url` is allow-listed against `api.deepseek.com` for the same reason.
- `XAIConfig.base_url` is allow-listed against `management-api.x.ai` (management keys only; inference host `api.x.ai` is rejected).
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
make validate           # runtime assertions + Swift Testing + coverage ≥90% + smoke launch + perms audit
make universal-check    # asserts the built app really is x86_64 + arm64
make sign-developer     # DEVELOPER_ID auto-detected when the keychain has exactly one
make notarize           # requires NOTARY_PROFILE (keychain) or APPLE_ID/APPLE_TEAM_ID/APPLE_PASSWORD
make release            # both notarized DMGs: arm64 + universal (sign app → DMG → sign DMG → notarize → staple)
make publish            # make release + upload both DMGs & checksums to the GitHub Release, flip draft → published
make ship               # full ritual: push → wait CI tag → pull bump → make publish
make clean
```

### Dependencies and testing

TOMLKit **0.6.0** is the only SwiftPM dependency; its embedded toml++ is **3.4.0**. Both remain at their latest published stable releases as checked on 2026-09-06. Tests use **Testing bundled with the selected Swift toolchain**, not a separately versioned `swift-testing` or `swift-syntax` package. This avoids mixing incompatible Testing runtimes and macros. See the [upstream distribution guidance](https://github.com/swiftlang/swift-testing/blob/main/Documentation/Distributions.md).

The Boolean assertion helpers have one canonical source at `Sources/AiTaskbarTestSupport/ExpectBool.swift`, compiled directly in each test target through relative symlinks. Keep those symlinks intact. Negative-control tests verify that deliberately false helper assertions are observed by the runner. After migrating an existing checkout, run `swift package clean` once before `make validate` to discard modules built against the former standalone package.

`make test`, `make coverage` and `make validate` preserve an explicit `DEVELOPER_DIR` or the selected full Xcode. When only CLT is selected, they use `/Applications/Xcode.app` if installed. This does not change the machine's global `xcode-select` setting or release commands. For another Xcode location, use `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer make validate`. For direct `swift test` commands, select the full Xcode with the same environment variable.

### Customize bundle identifier

```bash
make BUNDLE_ID=com.yourorg.aitaskbar app
```

### Code-signed distribution (optional, requires paid Apple Developer ID)

```bash
# One-time: store the app-specific password (from account.apple.com) in the
# keychain so it never touches env vars or shell history:
xcrun notarytool store-credentials my-profile --apple-id you@example.com --team-id TEAMID12345

NOTARY_PROFILE=my-profile make release
```

This one-time step is per-machine, and without it every release builds both
DMGs and then stops at `notarize`. Check whether it was already done by
**using** the profile — never by searching the keychain:

```bash
xcrun notarytool history --keychain-profile my-profile
```

`Successfully received submission history` means it works. A keychain query
like `security find-generic-password -s "com.apple.gke.notary.tool"` returns
nothing **even when working profiles exist** — notarytool does not store them
where that looks, so its silence is a false negative, not an answer.

`DEVELOPER_ID` is auto-detected when the login keychain holds exactly one
`Developer ID Application` certificate. Set it explicitly when you have more
than one — the Makefile refuses to guess, because signing a release under the
wrong team only surfaces once notarization comes back attached to the wrong
account:

```bash
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID12345)"
```

(Alternatively pass `APPLE_ID` + `APPLE_TEAM_ID` + `APPLE_PASSWORD` env vars
instead of `NOTARY_PROFILE`.)

Result: a DMG that opens with **no Gatekeeper warnings** on any macOS 11+ Mac. Without this, you get the one-time warning described in [Install](#install).

## Releasing a new version

Tagging is **automatic**, publishing is **local**. Every push to `main`
(typically a PR merge) runs [`auto-tag.yml`](.github/workflows/auto-tag.yml),
which:

1. Picks the next version from the commit messages since the last tag.
2. Bumps the version in `Makefile`, `Bundler.toml`, `Resources/Info.plist`, and
   `AboutView.swift`, then commits `chore(release): vX.Y.Z [skip release]`.
3. Pushes an annotated `vX.Y.Z` tag.
4. Calls [`release.yml`](.github/workflows/release.yml), which validates the
   tagged commit and creates a **draft** GitHub Release with generated notes —
   no DMG is built in CI. The Developer ID private key never leaves the
   maintainer's Mac (no signing secrets in the repo).

The maintainer then publishes the assets locally. One command does the whole
ritual (push → wait for CI to tag → pull the bump → publish):

```bash
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID12345)"
NOTARY_PROFILE=my-profile make ship
```

(`make publish` is the second half alone, for when the tag already exists
locally; `ship` aborts cleanly if the head commit opted out via
`[skip release]`.)

`make publish` checks the signing identity and notarization credentials in its
first second — before building anything — then refuses to run on a dirty tree or
when `HEAD` isn't the tagged release commit. Once a later commit lands on
`main`, publish from the tag instead:

```bash
git checkout v0.16.1 && make publish && git checkout main
```

It then builds, signs and notarizes **two DMGs** —
`ai-taskbar-X.Y.Z-arm64.dmg` (Apple Silicon, smaller) and the universal
`ai-taskbar-X.Y.Z.dmg` — uploads both plus a `checksums-X.Y.Z.txt`, and flips
the release from draft to published. The in-app update checker picks the DMG
matching the user's architecture (drafts are invisible to it, so users never
see an asset-less release).

### Choosing the bump level

The level is matched against the commit subjects/bodies since the last `v*` tag:

| Bump  | Trigger                                                              |
|-------|---------------------------------------------------------------------|
| major | a body line **starting** with `BREAKING CHANGE:` (exact case), a `type!:` subject, or `[bump:major]` |
| minor | a `feat:` / `feat(scope):` subject, or `[bump:minor]`               |
| patch | anything else (the default — this repo uses free-form subjects)      |

To push to `main` **without** cutting a release (docs-only tweaks, etc.), put
`[skip release]` anywhere in the head commit message.

### Cutting one manually

You can still tag by hand (e.g. for a backfill or a pre-release):

```bash
git tag v0.2.0-beta1
git push origin v0.2.0-beta1
```

The [release workflow](.github/workflows/release.yml) runs on GitHub-hosted
macOS runners and does exactly two things:

1. Run the validation suite against the tagged commit.
2. Create a **draft** GitHub Release with auto-generated notes.

It builds **no DMG and attaches no asset** — that has been true since v0.7.3,
for the reason given above: the Developer ID private key stays on the
maintainer's Mac. Pushing a tag therefore gets you a draft and nothing else;
run `make publish` locally to put binaries on it.

Pre-releases: tag like `v0.2.0-beta1` — the workflow marks them as pre-release automatically.

## Architecture

```
AiTaskbarApp/             SwiftUI MenuBarExtra + popover + About + UpdateChecker
  ViewModels/             UsageStore (coordinator) + VendorViewModel (per vendor)
  Views/                  VendorSectionView (accordion), Sparkline, MenuBarLabel
  Localization/           L10n.swift + Resources/<lang>.lproj/Localizable.strings
AiTaskbarProviders/       8 providers — all use CachedFetch + OAuthRefresher helpers
AiTaskbarCore/
  Models/                 UsageSnapshot, FetchOutcome, AppError, VendorId
  Networking/             HTTPClient (ephemeral session), PinStore, PinningDelegate
  Cache/                  DiskCache (TTL+stale fallback), AtomicFileWrite
  Credentials/            Keychain, File, EnvOrConfig readers + JSONValue
  Config/                 AppConfig + ConfigLoader (TOMLKit) + flexibleDouble
  Cost/                   ClaudeSessionScanner, CodexSessionScanner,
                          CodexCost (source selection), CodexLogScanner
                          (legacy sqlite fallback), PricingTable
  History/                UsageHistoryStore (persistent JSONL + NSLock)
  Util/                   Paths, JWT, Semver, SharedCoders
AiTaskbarValidate/        Standalone runtime assertions (works with CLT-only setups)
AiTaskbarTesting/         Fixtures + StubURLProtocol (shared by tests + validate)
AiTaskbarTestSupport/     Canonical Boolean helpers, symlinked into tests (not an app target)
Tests/                    Swift Testing suites (toolchain-bundled framework)
```

See [CLAUDE.md](CLAUDE.md) for the architectural deep dive, hard rules, and the checklist for adding a new vendor.

## Contributing

1. Run `make validate` before opening a PR — the gate has to be green.
2. New vendor → follow the checklist in [CLAUDE.md](CLAUDE.md) ("Adding a new LLM vendor").
3. New strings → add to all three `.lproj/Localizable.strings` files.
4. Architectural changes → update [CLAUDE.md](CLAUDE.md) at the same time.
5. The `AiTaskbarValidate` target is the day-to-day test cover; XCTest in `Tests/` is for the day full Xcode is the developer tool of choice.

## License

MIT — see [LICENSE](LICENSE). Inspired by [`akitaonrails/ai-usagebar`](https://github.com/akitaonrails/ai-usagebar) (Linux/Waybar).
