---
status: resolved
trigger: Reset asks the user to log into Codex again despite an existing session.
created: 2026-09-06
---

## Symptoms and evidence

The user's screenshot shows eligible usage and a local authorization error.
Read-only field-presence checks established that the credential file uses
`tokens.account_id` and its ID token uses a nested OpenAI auth claim. Neither
format was recognized by reset account resolution. No credential values are
recorded here. Preparation fails before the first RPC, not during token renewal.

## Current Focus

- hypothesis: Native account parsing is missing; fixtures covered legacy shapes only.
- next_action: Commit and push the validated correction to PR #17, as authorized by the user.
- scope: Preserve read-only defaults, server identity checks and explicit reset confirmation.
- execution: Inline debugging; independent review agents are required by AGENTS.md.

## Verification

RED: `make validate` failed with 8 issues in the 636-test suite. A focused rerun
confirmed native-file preparation throws `authorization` before the first RPC;
native reader account is nil, writeBack loses nested identity, and a numeric
legacy JWT claim incorrectly reaches RPC. Logs: `/tmp/ai-taskbar-codex-account-red.log`
and `/tmp/ai-taskbar-codex-account-red-detail.log`.

GREEN: `make validate` passed: 637 tests, 314 runtime assertions, 91.89% line
coverage, signed bundle smoke launch, credential permission audit and zero
warnings outside the legacy Keychain allowlist. Log:
`/tmp/ai-taskbar-codex-account-green.log`.

Independent correctness, security and performance/dependency-delta reviews
passed without blockers. Coordinator Swift review found no added actor/shared
state, unsafe Sendable changes or new error swallowing. No dependency changes.

The app bundle's Developer ID signature was separately verified against team
`5HHL78743R`. After reopening it through macOS LaunchServices, the user reported
on 2026-09-06: "ok, me parece que resolveu". This supports resolution of the
reported account-reading failure; it does not establish that a real reset was
consumed. Automated tests use synthetic files and RPCs, not real reset credits
or OAuth renewal.
