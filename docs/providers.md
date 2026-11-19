[← Back to the README](../README.md)

# Provider setup & troubleshooting

Quick setup for each provider is in the [README](../README.md#supported-providers). This page covers what each card reads, why, and how to recover when something goes wrong.

> ⚠️ **macOS env vars footgun:** GUI apps launched from Finder do **not** inherit your shell environment. If you set `OPENROUTER_API_KEY=...` in `~/.zshrc`, the menu bar app **won't see it**. Three workarounds:
> 1. **Put the key directly in `config.toml`** (file is `chmod 600`).
> 2. Launch from a terminal: `OPENROUTER_API_KEY=sk-... open /Applications/AiTaskbar.app`.
> 3. Set it globally: `launchctl setenv OPENROUTER_API_KEY "sk-..."` (until reboot).

## OAuth recovery — **Authorize** vs **Re-login**

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

## Claude Code on macOS — Keychain access

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

## Several Claude accounts on one Mac

Claude Code keeps each account in its own config folder: `~/.claude` for the
default login, and the folder in `CLAUDE_CONFIG_DIR` for every other one
(for example `CLAUDE_CONFIG_DIR=~/.claude-work claude`). AI Taskbar finds them
on its own: every `~/.claude-<name>` (also `_` or `.` as the separator) that
holds a logged-in config and whose Keychain item exists becomes an account.
Folders elsewhere go in `config_dirs` under `[anthropic]`.

The accounts share the Claude card, with ‹ › arrows and dots to switch
between them (hovering an arrow shows the account it leads to; the ← / →
keys switch too, on the home and Analytics pages); a dot ringed in orange is
a hidden account that needs a look (error, Authorize, expired login, or
usage at the warning threshold). Each
account has its own usage bars, cost, history and notifications. Pinning
the card pins one menu-bar item that shows the account the card is showing:
switch accounts and the pinned % switches with it. The Analytics card offers
**All** (every account's cost and tokens; usage % and history from the most
used account, since percentages don't add up) plus one view per account. The
default account is named "main" and the others after their folder
(`.claude-work` → "work").

Discovery reads no secret: it checks that each account's Keychain item
exists from its attributes only, and reads the account id from the config
file. Leftover Keychain items from deleted folders and copied backup folders
are ignored. An account added or logged out while the app is running shows a
"relaunch" banner. Every account is read-only; `manage_oauth_refresh`,
`keychain_service` and `keychain_account` apply to the default account only.

## Claude `429 rate_limit_error`

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

## OpenAI / Codex — credits are a quantity, not money

Codex reports paid usage credits as a bare decimal with **no currency symbol**:
the wire literally carries `"balance": "4890.3162520000"`. Earlier builds parsed
it with a `parseDollar` helper, stored it as `creditsUSD` and rendered
`Credits: $4890.32`, inventing a `$` the API never sent. Nothing in the app
formats credits as currency any more; the card shows a locale-formatted
quantity.

**Progress bar.** The payload reports only the *remaining* balance — there is
no granted total anywhere in it (`spend_control.individual_limit` and `promo`
are null on real accounts), so a percentage needs a denominator the app derives
itself: the highest balance it has ever observed, persisted per vendor in
`~/Library/Application Support/ai-taskbar/credits/<vendor>.json`. A balance
*above* that high-water mark can only be a top-up, which re-baselines the bar to
0%. **No bar is drawn until the baseline says something the balance does not**:
on the first sighting the peak *is* the balance, and a green 0% there would
tell someone who had already burned 90% of their credits that they had spent
nothing. The bar appears as soon as real consumption is observed, and is exact
after the next top-up. Unmetered accounts (`unlimited: true`) get no bar at
all, and a missing or garbled balance shows the plain number.

**Telling an expiry from ordinary spending.** A balance that falls is normally
consumption, but it is a grant change when a promotional block expires — and
from the number alone the two are identical. Rather than guess from the size of
the drop (a heuristic that would mistake a heavy day for an expiry and vice
versa), the app reads the two epoch signals the payload actually carries:
`has_credits` going false then true means credits came back after running out,
and a `promo` object that was present and is now absent means a promotional
grant ended. Either one re-seeds the denominator from the current balance. Only
the *presence* of `promo` is used; its inner shape has never been seen
populated on a real account, so nothing reads inside it.

One case remains that no signal can catch: a promotional block shrinking while
other credits remain, which looks exactly like spending. For that, right-click
the credits row and choose **Recalibrate credits bar** — it forgets the
baseline and re-seeds from the current balance on the next refresh.

The credits bar is deliberately **not** folded into the menu-bar percentage.
That number tracks plan windows which reset on a clock; credits drain on a
different axis against a locally-derived denominator, and mixing them would make
the menu bar read 80% because of credits while the plan sits at 10%.

**Credit-funded messages.** `approx_local_messages` and `approx_cloud_messages`
live *inside* the `credits` object, so both are estimates of what the remaining
credits still buy. They mean different things — the local Codex CLI versus cloud
tasks — and both are now shown, labeled as credit-funded. The old code collapsed
them into one English sentence built inside the provider (which is why a
Portuguese card showed `local msgs left`) and silently preferred whichever came
first. When the plan window is spent (`allowed: false`) and credits are covering
requests, the card says so instead of showing a bare red 100% bar that reads like
a block. "Requests are blocked" is claimed only when the plan window is spent
*and* the overage ceiling is hit — an overage ceiling on its own stops nothing
while the plan still has room. A drained balance says "credits used up" rather
than leaving a red bar unexplained.

## OpenAI / Codex — earned rate-limit resets

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
attempt. See the [implementation SDD](SDD-native-authorization-and-openai-reset.md)
for the protocol, security boundaries, tests and manual acceptance checks.

## Claude — limit resets (Fable, weekly, 5-hour, full)

Claude Code now hands out earned **limit resets** (its `/limit-reset
[fable|full|5-hour|weekly]`): a *weekly reset* clears the weekly limit, a
*Fable reset* gives back to the weekly limit what Fable used. The Claude card
offers them under the **same rule as OpenAI**: a current, healthy snapshot
with a window **above 90%** that the reset refills, and at least one usable
reset of that kind. Each kind gets its own button (e.g. **Use Fable reset (1)**,
**Use weekly reset (1)**); clicking re-reads the grants, then an in-window,
click-only confirmation names the account, the reset and how many remain.

Anthropic serves resets only to the Claude Code CLI surface at a recent
version, so the reset calls (the status read, made only while a window is
above 90%, and the claim) identify as the **installed** Claude Code
(`claude-cli/<version> (external, cli)`, version read from its install
folder). Without Claude Code installed the buttons never appear. The credential
stays read-only: nothing is refreshed or written back. A lost response can be
retried with the same request id, which the server dedupes. See
[docs/SDD-claude-limit-reset.md](SDD-claude-limit-reset.md).

## xAI (Grok) — SuperGrok CLI monitoring & API team billing

> ⚠️ **Important requirement:** xAI does **not** provide a public REST API for querying individual SuperGrok / grok.com quotas or token balances. To monitor your SuperGrok usage and quota, you **must have the official Grok CLI installed and authenticated locally** (`grok login`).

AI Taskbar supports two modes for xAI:

1. **Grok CLI mode (default & recommended):**
   - **How it works:** AI Taskbar reads the local session credentials at `~/.grok/auth.json` (created upon running `grok login`) and queries Grok's internal billing proxy (`https://cli-chat-proxy.grok.com/v1/billing?format=credits` and `v1/settings`) using your authenticated Bearer token.
   - **What the card displays:**
     - **Subscription tier:** Identifies active tier (e.g. `SuperGrok Heavy`).
     - **Weekly quota window:** Current utilization percentage (e.g. `3% used`) and reset time.
     - **Prepaid balance:** Available balance (e.g. `$40.00 available`).
     - **Disclaimer:** An in-card informational notice reminds you, in the app's language, that Grok CLI must remain installed and logged in (e.g. *"To monitor Grok, Grok must be installed and authenticated."*).
   - **Setup:** Simply install the Grok CLI and run `grok login` in Terminal. No manual API keys or team IDs needed in `config.toml`.
   - **Recovery / 401:** If the token expires or is missing, the card displays a **Re-login** button that executes `grok login`.

2. **Management API mode (for team/developer spend):**
   - If you do not use the Grok CLI and wish to track developer API credit spend instead, set `prefer_grok_cli = false` under `[xai]` in `config.toml`.
   - Requires a **Management key** from [console.x.ai](https://console.x.ai) → Settings → Management Keys (not an inference API key) and your Team UUID (`team_id`).
   - Reads prepaid balance and current-cycle postpaid invoices from `management-api.x.ai`.

---

## TypeSafe (Jev) — API key, plus optional console sign-in

[Jev](https://docs.typesafe.ai) is TypeSafe AI's "System One" model: it returns typed decisions (choice, score, yes/no probability), not chat text. The card is **off until you save an API key** in Settings → Jev (TypeSafe).

- **What the card shows:** whether the key is accepted and which models it can call (`jev-latest`, `jev-preview`), from `GET /v1/models` — a call that costs nothing. The app never runs an evaluation (`/v1/systemone`), because every evaluation bills tokens and would appear in your own usage.
- **Spend, balance and tokens need a console sign-in:** TypeSafe's public API has no usage or billing endpoint for API keys; those numbers live in the [TypeSafe console](https://console.typesafe.ai/usage). Click **Sign in to TypeSafe…** on the card (or Settings → Jev (TypeSafe) → Console): the console's own login page opens in a private in-app window, you sign in as usual (Google, e-mail), and the window closes by itself. The card then shows the cycle spend and balance the console reports, live credits with their expiry, and today's / last 7 days' tokens and requests. Nothing to copy, no browser or terminal involved.
- **What is kept:** only the three login cookies (`session`, `session_id`, `organization_id`), encrypted in `config.toml` (0600), sent only to `console.typesafe.ai`, never logged or cached. The window uses a non-persistent store, so your browsers' cookies are never read. Personal data the console returns (e-mail, billing address, payment method, key names) is never decoded. The session lasts ~14 days; the card warns two days before and offers **Sign in again**. **Sign out** in Settings deletes it.
- **No menu-bar percentage:** there is no quota to measure, so the provider can't be pinned and never moves the menu-bar gauge.
- **Status:** incidents from [status.typesafe.ai](https://status.typesafe.ai). Its feed publishes one item per update, so updates are merged per incident, and an unresolved incident with no update for 48 h is treated as abandoned rather than ongoing.
- **Pricing (for reference, not used by the app):** US$ 0.042 per million input tokens, output free ([docs.typesafe.ai/models](https://docs.typesafe.ai/models), checked 2026-09-29).

## Meta (Muse) — CLI-login quota plus local token history

Muse is Meta's model family behind the Muse Code CLI (`muse`). The card is **off until you enable it** in Settings → Muse (Meta), and it needs the CLI login: run `muse login` once.

- **What the card shows:** your plan and the subscription windows (session + weekly, with reset countdowns) read from Meta with the CLI's own login token, plus today's / last 7 days' tokens per model from the CLI session logs on this Mac (`~/.local/share/muse/sessions`). Pay-as-you-go accounts show "No subscription" instead of an invented 0% bar.
- **Weekly quota while the session is idle:** Meta's response leaves out every window while the 5-hour session window is idle — including the weekly one, which is exactly what a spent weekly cap causes. The card therefore keeps showing the **last weekly reading** (marked "last reading …", with its time) until that window's reset, and it still counts toward the menu-bar percentage. Weekly usage only grows until it resets, so the figure is a lower bound, never an invented number. The reading belongs to the plan it was taken under (a plan change does not inherit it), and `muse logout` forgets it. With no reading at all (for example, the week was spent before this version first saw it), the card says the weekly usage is unknown, links to dev.meta.ai, and the 24 h chart leaves a gap instead of plotting 0% — the Muse CLI itself reports `server_sent_no_usage` then (`muse usage`). It is kept in `quota/meta.json` (a percentage and a reset date, no secrets).
- **No API key works here:** dashboard keys and `META_API_KEY` cannot read subscription quota, so there is no key field. The login token is used only to fetch the windows, is never logged, and is never refreshed by the app — the CLI owns it.
- **Keychain access, once:** the CLI keeps its login in the macOS Keychain, and the app never pops a password prompt on its own. The first time, the card shows **Authorize**: click it and choose **Always Allow**. The app then keeps its own copy of the login token, encrypted and bound to this Mac (`credentials/meta-token`, 0600), because every Muse self-update rewrites the Keychain item and drops the permission you gave — without the copy the card would ask again after each update. It asks again only when Meta rejects the copy (for example after `muse login` with another account); if Meta rejects the login itself, the card tells you to run `muse login` instead. `muse logout` deletes the copy. Scope, honestly: the copy is useless if the file is copied off this Mac, but any program running as you on this Mac could read it — a step down from the Keychain, accepted because the alternative is a password prompt after every Muse update.
- **Dollar figures are API-value estimates:** local tokens are priced at the published Meta Model API rates (Muse Wonder $4/$20 per 1M in/out, Spark $1.25/$4.25). Wonder Full has no public per-token rate (subscription-only), so it is estimated at the Wonder rate; subscription use itself is flat-fee.
- **Status:** the row links to Meta's official [metastatus.com](https://metastatus.com); it exposes no machine-readable feed we could verify, so live incident state stays "unknown" (link-only, like Gemini) rather than scraped.

## Google Gemini — Antigravity CLI monitoring & heartbeat

> ⚠️ **Important requirement:** Google does **not** provide a public REST API for personal Gemini subscription quotas (such as the 5-hour or weekly consumer limits on gemini.google.com). To monitor Gemini quotas and models, you **must have Google's Antigravity CLI (`agy`) installed and authenticated locally**.

AI Taskbar supports two monitoring paths for Google Gemini:

1. **Antigravity CLI mode (default & recommended):**
   - **How it works:** AI Taskbar executes the local Antigravity CLI in the background (`agy --output-format json --print "/usage"`) with a 35-second budget, closed standard input, stdout capped at 4 MiB (a larger answer is rejected, not parsed) and stderr truncated to 64 KiB.
   - **Binary auto-detection:** Automatically discovers `agy` in standard install paths:
     - `~/.local/bin/agy`
     - `/opt/homebrew/bin/agy`
     - `/usr/local/bin/agy`
     - `~/.gemini/antigravity/bin/agy`
     - Or specify an explicit path via `agy_path = "/path/to/agy"` under `[gemini]` in `config.toml`.
   - **What the card displays:**
     - **Gemini (5h):** Session quota window utilization and remaining fraction.
     - **Gemini (Weekly):** Weekly quota window utilization and reset countdown.
     - **Third-party models (5h & Weekly):** Tracks secondary quotas for third-party models accessed through Antigravity (e.g. Claude).
     - **Disclaimer:** When Antigravity is unauthenticated or missing, the card shows a clear notice in the app's language (e.g. *"To monitor Gemini quotas, Antigravity must be installed and authenticated."*). A quota bucket that `agy` reports without a `remaining_fraction` draws no bar rather than being shown as 100% remaining.
   - **Setup:** Install the Antigravity CLI and log in by running `agy` in Terminal.
   - **Recovery / 401:** If the session is unauthenticated, clicking the **Re-login** button runs `agy` in Terminal to re-authenticate.

2. **API Key Heartbeat (fallback):**
   - If you do not use Antigravity, you can set `prefer_antigravity = false` and supply a Google AI Studio API key (`api_key = "AIza..."` or `GEMINI_API_KEY`).
   - Acts strictly as an authenticated heartbeat (`GET /v1beta/models`) to check key validity and count available models. Developer keys do not expose subscription usage or remaining quotas.

**Per-model usage & cost (local estimate):** independently of the quota path above, the card's cost footer breaks down the models you actually used — tokens and estimated dollars per model for today and the last 7 days. Google exposes no per-model usage API, so AI Taskbar reads the clients' own local records: Gemini CLI chat logs (`~/.gemini/tmp/*/chats/session-*.jsonl`) and Antigravity's conversation databases (`~/.gemini/antigravity-cli/conversations/*.db`), priced at published Google AI rates. It is an API-value estimate, not a bill: subscription use has no marginal cost. Quota bars stay group-based (that is all `agy /usage` reports); the footer is where real per-model consumption lives.
