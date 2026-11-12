# SDD — Claude limit resets (Fable, weekly, 5-hour, full)

Status: implemented 2026-11-12. Counterpart of
`SDD-native-authorization-and-openai-reset.md` (OpenAI earned resets).

## 1. What exists upstream (measured, not documented)

Claude Code 2.1.322 ships `/limit-reset [fable|full|5-hour|weekly]`
(internal program name `cedar_ember`). Read from the CLI bundle and checked
against the live API with a Max account on 2026-11-12:

- **Status:** `GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1`
  (Bearer OAuth, `anthropic-beta: oauth-2025-04-20`). Without the parameter
  the block is `null`. Shape:

  ```json
  "cedar_ember": {
    "eligible": true, "ineligible_reason": null, "at_limit": false, "exhausted": [],
    "grants": [{ "id": "full-reset-2611", "label": "One full limit reset (November 2026)",
                 "resets_total": 1, "resets_left": 1, "starts_at": "…", "ends_at": "…",
                 "clears": ["seven_day", "seven_day_overage_included"], "paused": false,
                 "usable_now": true, "use_requires_limit": false, "percent_used": {…},
                 "blocking": [], "type": "weekly", "gives_back_weekly": false,
                 "unavailable_reason": null }, …],
    "next_grant_id": "full-reset-2611", "weekly_resets_at": "…", "cooldown_until": null,
    "event_props": { "surface": …, "tier": …, "tenure_bucket": …, "billing_path": … }
  }
  ```

- **Claim:** `POST https://api.anthropic.com/api/organizations/{orgUUID}/reset_rate_limits`
  body `{"program":"cedar_ember","grant_id":…,"request_id":…}`; grant id
  `^[a-z0-9_-]{1,40}$`, request id `^[A-Za-z0-9_-]{1,64}$`. Answer
  `{result: reset|already_used|not_limited|cooldown|ineligible|unavailable,
  reason, resets_left, cleared, weekly_resets_at, cooldown_until}`; 429 is
  rate limited, 401/403 auth.
- **Kinds** (Claude Code's own rule): `gives_back_weekly` → Fable; else the
  `type`; else only `five_hour` → 5-hour, only others → weekly, both → full.
  `seven_day_overage_included` is the model-scoped weekly limit (Fable).
- **Surface gate.** The status is `eligible` only for the Claude Code CLI at a
  recent version: `claude-cli/2.1.322 (external, cli)` → eligible;
  `claude-cli/1.0 (external, cli)` → `cli_version`; `claude-cli/1.0`,
  `ai-taskbar/… (external, cli)` → `surface`.

## 2. Decision: present the installed CLI on reset calls only

Chosen by the maintainer on 2026-11-12 over (b) a button that opens Claude Code
and (c) not shipping. The reset calls send
`claude-cli/<installed version> (external, cli)`; every other Anthropic call
keeps `claude-cli/1.0`. The version is read from the install location
(`ClaudeCLIVersion.installed`: launcher symlink, versions folder, Homebrew
cask, npm manifest — never by running the binary) and validated to
`digits.digits.digits` because it goes into a header. No CLI installed → no
status read and no button. This deliberately passes the surface gate; it is
the user's own grant, spent only on an explicit, confirmed click.

## 3. Rule (same as OpenAI)

`AnthropicSnapshot.limitResetOffers(now:)` offers a kind when a grant of it
is usable (`resets_left > 0`, not paused, no `unavailable_reason`, inside
`starts_at…ends_at`) AND a window it refills is **strictly above 90%**,
finite, and not past its own reset time. `ClaudeResetController.offers` adds
the OpenAI freshness gate: `.ok`, not stale, no `lastError`, fetched
−5…300 s ago. One button per kind, in Claude Code's order (5-hour, weekly,
Fable, full); the count is the sum over that kind's grants. The claim targets
the server's `next_grant_id` when it is of that kind, else the grant
expiring first.

Windows a grant refills: `five_hour` → session, `seven_day` → weekly,
`seven_day_opus` → Opus, `seven_day_overage_included` → model-scoped rows;
`gives_back_weekly` adds weekly; a full grant with no `clears` refills all.

## 4. When the status is read

`AnthropicProvider` asks for `?cedar_ember=1` (as the CLI) only while a window
is above 90% — the only time a button can show. The fetch that first crosses
90% makes a second call; while it stays above, the one call carries the
status. A failed status call is logged and the plain payload is kept: it can
cost the button, never the usage numbers.

## 5. Claim flow and safety

`ClaudeLimitResetService` (Providers):

1. **prepare(kind)** on click: credential read-only (never refreshed or
   written back) → `GET /api/oauth/profile` (decodes ONLY `account.uuid` and
   `organization.uuid`; e-mail and names are never decoded) → status → rule.
2. **Confirmation**: in-window `ConfirmationRequest`, destructive, so Return
   never confirms; names account, kind, the server's grant label and the count.
3. **consume**: profile again (account or org changed → `accountChanged`);
   for a first attempt the status again (grant gone or rule no longer met →
   `noEligibleReset`); then the POST.
4. **Errors**: transport failure, 5xx or an unreadable 2xx →
   `submissionUncertain` (the request may have landed): the controller keeps
   the attempt and the next click resumes it with the SAME `request_id`.
   429/401/403/other 4xx are definitive and drop it. An unknown `result` is
   read as `unavailable`, never as a reset.
5. The pending attempt lives with the account's view model (survives closing
   the popover), in memory only. Unlike OpenAI there is no journal: a relaunch
   starts over, and a new attempt re-reads the grants before claiming.

The org UUID and grant id are validated before they reach the URL/body.

## 6. Tests

- `ClaudeLimitResetTests` (Providers): golden decode of a real-shape fixture
  (`Fixtures.anthropicUsageWithResets200`), classification, the rule (exactly
  90%, Fable-only, expired / not started, awaiting reset, session, full, NaN),
  Codable back-compat, every service path (headers, URL, body, retry without
  re-check, account change, uncertain vs definitive errors, tampered input),
  and the provider's conditional status read.
- `ClaudeCLIVersionTests` (Core), `ClaudeResetControllerTests` (App).
- `ai-taskbar-validate`: "Wire types: Claude limit resets (cedar_ember)".
