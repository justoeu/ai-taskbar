[← Back to the README](../README.md)

# How it works

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

Every usage window's percentage is sanitized when it is built and again when it is read back from the cache: NaN becomes 0 and the value is clamped to 0–1000%, so a vendor reporting overuse still shows above 100% but a corrupt or hostile number cannot reach the bars or the menu-bar gauge.

The per-vendor `DiskCache` TTL is wired to `max(15, refresh_interval_seconds − 5)` in `AppEnvironment`. The 5 s margin means a scheduled tick at T=interval always sees an expired cache (`age ≈ interval > ttl`), so the scheduler doesn't need `forceRefresh: true` to defeat the cache. Popover opens between scheduled refreshes still serve from cache.


## Service status & health pages

AI Taskbar features an integrated **Service Status & Health Dashboard** that monitors upstream operational availability, active incidents, and scheduled maintenance across supported providers.

- **How to open:** Click the status indicator icon in the popover header to open the dedicated status window.
- **6-hour sliding window:** Tracks incidents within the `[now - 6h, now]` interval, displaying progress phases (Investigating, Identified, Monitoring, Resolved).
- **Aggregated health:** Evaluates overall service state using worst-case severity (Operational, Degraded Performance, Partial Outage, Major Outage).
- **Official status sources:**

| Provider | Official Status Page | Integration Type |
|---|---|---|
| **Anthropic (Claude)** | [status.claude.com](https://status.claude.com) | Statuspage API |
| **OpenAI (ChatGPT/Codex)** | [status.openai.com](https://status.openai.com) | Statuspage API |
| **Google Gemini / AI Studio** | [aistudio.google.com/status](https://aistudio.google.com/status) | Official Health Page |
| **xAI (Grok)** | [status.x.ai](https://status.x.ai) | RSS Status Source |
| **DeepSeek** | [status.deepseek.com](https://status.deepseek.com) | Status API |
| **Kimi (Moonshot)** | [status.moonshot.cn](https://status.moonshot.cn) | Statuspage API |
| **OpenRouter** | [status.openrouter.ai](https://status.openrouter.ai) | RSS Status Source |
| **Jev (TypeSafe)** | [status.typesafe.ai](https://status.typesafe.ai) | RSS Status Source (one item per update, merged per incident) |
| **Z.AI** | *(None)* | Unmonitored (no public status page) |
| **Muse (Meta)** | [metastatus.com](https://metastatus.com) | Official Status Page (link only — no machine-readable feed wired yet) |

Clicking any row in the status window opens the provider's official status page directly in your browser.


## Pinned LLMs in the menu bar

Expand a provider's card and turn on **Pin to menu bar**. The provider gets its own item — its icon plus the current %, or weekly and session % stacked for providers that report both (a plan with no session window — e.g. Claude Ultra, which has no 5-hour limit — shows the weekly % alone, never the same figure twice) — rendered in the same system menu-bar font as the main gauge.

- **Order:** the first pin sits immediately left of the main gauge; each later pin goes one slot further left. Unpinning and re-pinning puts the provider back at the end of that sequence.
- **Click** a pinned item to open the popover focused on that provider's card; click it again to close.
- **Tooltip:** hover for the provider's windows and their daily / weekly reset countdowns.
- **Space limit:** macOS hides menu-bar items that don't fit, so pinning is refused — with an explanation — when the next item would collide with the camera notch (or cover the app menus on displays without one), and after 5 pins. The check measures the real bar and the widest a badge can grow, so on a 14" MacBook with many system icons you may only have room for two.
- The check runs when you pin. If another app later adds icons, macOS may still hide the leftmost ones; unpin one to make room.


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


## Privacy & security — full list

- Anthropic OAuth tokens stay in the **Keychain** — the app reads them, never copies them to disk.
- **The OAuth providers are read-only by default** (`[anthropic] manage_oauth_refresh = false` and `[openai] manage_oauth_refresh = false`). A usage monitor shares the `Claude Code-credentials` Keychain item with the Claude Code CLI and `~/.codex/auth.json` with the Codex CLI, and both vendors rotate the refresh token on every exchange — so refreshing it here would invalidate the token other running CLI sessions hold (forcing "please re-login"), and the Anthropic write-back also trips a Keychain ACL prompt on ad-hoc builds. In read-only mode the app uses whatever token the CLI maintains and lets the CLI own renewal; if the token is briefly expired the last cached snapshot is shown until the CLI refreshes (on a cold cache with no prior snapshot the vendor tile shows the error until renewal). Set `manage_oauth_refresh = true` for a vendor only if you run AI Taskbar standalone without that CLI.
- Keychain reads **and** writes run under `KeychainPromptSuppressor` (`SecKeychainSetUserInteractionAllowed(false)` around every SecItem call) **in addition to** `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`. The UIFail hint alone only silences the trusted-app Allow/Deny confirmation — the partition-list **password** dialog ignores it and used to pop on every scheduled refresh from a binary the ACL didn't recognize. With both in place, a blocked binary fast-fails (`errSecInteractionNotAllowed` / `errSecAuthFailed`) instead of prompting; the renewed access_token is kept in memory and persistence retries on the next OAuth cycle. The log directs the user to the in-app Authorize button.
- When a scheduled read is blocked, the Claude card shows **Authorize**. Its sole interactive read targets one exact item. macOS owns consent; a silent same-item probe is mandatory. The reader binds subsequent reads and opt-in writes to that persistent reference, and never carries pending tokens onto a different or recreated credential.
- `make app` signs local builds with your **Developer ID Application** identity when the login keychain has one, so one Authorize covers subsequent signed rebuilds. The bundle assembly can fall back to ad-hoc signing, but durable authorization fails closed there because an ad-hoc identity cannot safely remain trusted across builds.
- Codex `~/.codex/auth.json` writes go through atomic tempfile with `0o600` set **before** the rename — no race window where fresh refresh tokens are world-readable.
- Configuration files (`config.toml`) and cache files are `chmod 0600`, support dir `chmod 0700`.
- **Inline secrets in `config.toml` are bound to this Mac.** Every `api_key` and the TypeSafe console session are stored as `enc:v2:` — AES-GCM with a key derived (HKDF-SHA256) from **this Mac's hardware UUID**, each value also bound to the field it lives in (a value copied into another field does not open). On launch, values still in plaintext or in the older `enc:v1:` format (key from the constant alone) are re-encrypted as `enc:v2:`; no backup copy is written (it would keep the plaintext on disk) — the rewrite is verified by re-reading it, and the original is put back if anything differs. On a new Mac or after a logic-board replacement the keys can no longer be read: the cards ask for them again and every other setting is kept. **What this protects:** the file on its own — pasted, shared on screen, attached somewhere, copied off the machine. **What it does not:** the UUID is not a secret (any local process, `ioreg`, System Information exports and Time Machine metadata expose it), so malware running as you, or someone holding a full image or Time Machine backup of this Mac, can derive the key. Copies made before the upgrade (older Time Machine snapshots, `config.toml.bak-*` files from "Restore defaults") still hold the old values; rotate those keys if that matters to you. The Keychain is deliberately not used here: it would prompt for your password and losing the item would lose every key.
- OpenAI cache strips `user_id`/`account_id`/`email` fields before persisting — only utilization data survives.
- `KimiConfig.base_url` is allow-listed against `api.moonshot.ai`/`api.moonshot.cn` to prevent API-key exfil via attacker-controlled config.
- `DeepSeekConfig.base_url` is allow-listed against `api.deepseek.com` for the same reason.
- `XAIConfig.base_url` is allow-listed against `management-api.x.ai` (management keys only; inference host `api.x.ai` is rejected).
- Optional **TLS pinning** with Trust-On-First-Use SPKI hashes for paranoid setups.
- Hardened-runtime entitlements ready for Developer ID signing (see [`Resources/entitlements.plist`](../Resources/entitlements.plist)).
- TOCTOU symlink refusal on cache + support directories.
- Credential, config and cache writes (`AtomicFileWrite`) refuse a symlinked destination file: the write fails and both the link and its target are left untouched. For a symlinked `config.toml` this means new vendor sections are not appended on launch (the refusal is logged) and Settings cannot save; edit the link's target by hand.
- All audit findings from a 5-agent code review are tracked and addressed; see [CLAUDE.md](../CLAUDE.md) for the policy.
