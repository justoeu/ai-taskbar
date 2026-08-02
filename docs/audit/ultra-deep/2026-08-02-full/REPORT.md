# Ultra-Deep Audit results — ai-taskbar

> **Progress:** 44/44 DONE (100%) · OPEN 0 · updated 2026-08-02 17:36:07 UTC · ✅ COMPLETE

> **Progress:** 42/44 DONE (95%) · OPEN 2 · updated 2026-08-02 17:27:24 UTC

> **Progress:** 35/44 DONE (80%) · OPEN 9 · updated 2026-08-02 16:54:34 UTC

> **Progress:** 21/44 DONE (48%) · OPEN 23 · updated 2026-08-02 16:31:25 UTC

> **Progress:** 18/44 DONE (41%) · OPEN 26 · updated 2026-08-02 16:25:02 UTC

**Mode:** full · **Date:** 2026-08-02 · **HEAD:** `ca68d01` · **Stack:** Swift (SPM), Python scripts

**Headline:** 44 findings — 0 CRITICAL, 18 HIGH, 21 MEDIUM, 5 LOW · **blocks_pr:** 15

## Sentinel deep — panel re-run (real refuters)

- **verification.status:** `verified`
- **panel_source:** `vote-files` ← must be `vote-files`
- **require_vote_files:** True
- candidates_in: 10 · panel_quorum kept: 3 · dropped: 7
- Vote files: `sec-deep/votes/C*-{REACHABILITY,IMPACT,DEFENSES}.json` (30 files)
- Refuter Tasks: one independent agent per lens (REACHABILITY / IMPACT / DEFENSES) over C1–C10
- **Survivors (SEC-*):** 3
  - `SEC-SEN-001` (HIGH/medium) On-disk pin file overrides PinBaseline (pin poisoning)
  - `SEC-SEN-002` (HIGH/medium) Update DMG downloaded without integrity check via URLSession.shared
  - `SEC-SEN-003` (MEDIUM/medium) HTTPClient.pinned fails open if PinStore cannot be created

Earlier Oracle-forged votes are **superseded**. Several HIGH candidates (default pin off, codex_auth_path, keychain_service, SecretBox, etc.) fell below 2/3 on reachability/impact.

## Other agents

Unchanged from full wave (Atlas, Nexus, Hermes, Hydra, Artemis, Forge, Prism, Argus).

## Artifacts

See pack directory paths printed at close of run.
