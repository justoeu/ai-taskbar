# Project: ai-taskbar

Native macOS menu-bar app monitoring LLM usage across Anthropic, OpenAI/Codex,
OpenRouter, Z.AI, and Kimi/Moonshot. Swift Package Manager, SwiftUI
`MenuBarExtra`, targets macOS 13+.

## Validation policy (MANDATORY)

**After EVERY code change, run `make validate`.** No exceptions. This is not
a suggestion — it's the gate before any change is considered done. The script
fails fast on the first regression and exits non-zero, so it doubles as the
CI contract.

```bash
make validate
```

What it runs (`scripts/validate.sh`):

1. `swift build -c debug` — catches compile errors across all targets.
2. `swift run ai-taskbar-validate` — **160+ runtime assertions** in
   `Sources/AiTaskbarValidate/main.swift`. Covers: wire-type fixtures for
   every vendor (Anthropic, OpenAI, OpenRouter, Z.AI, Kimi, Gemini), OAuth
   error parsing, JWT decode, AppError equality + `isRateLimited`,
   JSONValue round-trip, KimiConfig URL validation, DiskCache TTL+stale
   semantics (default TTL = 300 s), AtomicFileWrite permissions,
   ConfigLoader TOML int↔double tolerance (default
   `refresh_interval_seconds = 300`), UsageHistoryStore append/load/compact,
   PricingTable, CostMath.
3. `swift test --no-parallel --enable-code-coverage` via `scripts/coverage.sh` —
   runs the Swift Testing suites in `Tests/` and reports line coverage on
   `AiTaskbarCore` + `AiTaskbarProviders`. Coverage floor is enforced via
   `COVERAGE_FLOOR` env var (see "Testing policy" below).
4. `make app` — assembles the `.app` bundle with ad-hoc code signature.
5. **Smoke launch** — `open build/AiTaskbar.app`, waits 3 s, confirms
   process is still alive, then kills it. Proves the Mach-O actually loads
   under SwiftUI's MenuBarExtra runtime.
6. **Permission audit** — verifies `~/Library/Application Support/ai-taskbar/`
   is `0700`, `config.toml` is `0600`, `~/.codex/auth.json` is `0600`.
   These hold credentials; loose perms are a security regression.

If any step fails, **fix it before claiming the work is done**. Don't paper
over with comments or `try?`-swallowing.

**Pre-commit / pre-PR gate (non-negotiable):** `make validate` must be green
**before** `git commit`, `git push`, `gh pr create`, or any tool that adds
follow-up commits to an existing PR. Order: stage → `make validate` →
commit/push/PR. On red, stop and root-cause; never commit on red and never
re-run `--no-verify`. This applies to every commit on a PR branch, not just
the first one — landing a broken commit and "fixing it in the next" still
breaks `git bisect` and CI for collaborators.

**PR review pipeline:** once a PR is open (or refreshed), fan out the
following passes in parallel and report a combined summary:

1. `/code-review` — correctness bugs in the diff.
2. `/security-review` — auth, secrets, file perms, host allow-lists,
   TOCTOU, TLS pinning, SAST.
3. Swift-best-practices Agent — Swift 6 strict concurrency
   (`Sendable`, `@MainActor`), `try?` discipline, `JSONValue` over
   `[String: Any]`, lenient TOML decoders.
4. Performance / CVE Agent — hot-path allocation, Combine fan-out,
   DiskCache I/O, SPM dep CVE scan.

## Testing policy (MANDATORY)

Two mandates with non-negotiable status:

### 1. Line coverage ≥ 90% on `AiTaskbarCore` + `AiTaskbarProviders`

Measured via `swift test --enable-code-coverage` + `llvm-cov report`,
filtered to those two targets only. Excluded:

- `AiTaskbarApp` (SwiftUI view bodies are out of scope — CLI-only coverage
  tooling can't meaningfully exercise them without an XCTest UI host).
- `AiTaskbarTesting` (fixtures/stubs by definition).
- `AiTaskbarValidate` (it IS a test runner; covering its body is circular).

Enforce with `COVERAGE_FLOOR=90 make validate`. Current ramp:

| Phase | `COVERAGE_FLOOR` | Status |
|-------|------------------|--------|
| now   | `0` (warn only)  | infra is in place; we report % but don't fail |
| soon  | `40` → `60` → `80` | tighten as gaps close |
| goal  | `90`             | hard fail in CI + `make validate` |

Don't ship new code that adds uncovered surface area. New file → new test.

### 2. Snapshot / golden testing on every vendor wire type

Each vendor in `AiTaskbarProviders` ships a `*WireTypes.swift`. Every
wire-type struct gets a **golden test**:

1. A canonical JSON fixture lives in `Sources/AiTaskbarTesting/Fixtures.swift`.
2. The test decodes that fixture, converts to `VendorSnapshot`, then
   compares the snapshot field-by-field against a frozen reference.
3. The reference values live in the test file itself (not in a separate
   golden directory) so a diff in the test = a deliberate schema decision.

The point: a careless edit to `*Snapshot` props or decoder logic must
fail the test, not "succeed silently with the wrong number." This is what
the user means by "imutabilidade" — the public Snapshot shape is a
contract, not an implementation detail.

### 3. Writing tests

- We use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not
  XCTest. XCTest doesn't work on Command Line Tools alone.
- Tests using `StubURLProtocol` must mark their suite `.serialized`
  AND `make test` runs with `--no-parallel`, because `StubURLProtocol.handler`
  is process-wide static state.
- Keep assertions atomic. One `#expect` per fact. Tests that fail with
  "expected 5, got 3" are useful; tests that fail with "got non-nil"
  send you to the debugger.
- For pure logic without I/O, you can still extend
  `Sources/AiTaskbarValidate/main.swift` — it runs faster than `swift test`
  for sanity checks and double-checks the `Testing` results.

### 4. When you implement anything new

- **New wire type / vendor** → golden test (see above). Not optional.
- **New file in Core or Providers** → at least one `@Test` covering its
  happy path. Aim higher; coverage gate enforces this.
- **New security surface** (e.g. inline secret in config) → add a
  permission check to `scripts/validate.sh`.
- **UI-only changes** that can't be asserted headlessly → exercise via the
  smoke launch and document what was visually verified in the PR.

## Build commands

```bash
swift build                    # debug build, all targets
swift run ai-taskbar           # run app from .build (no .app bundle, will Dock-icon)
swift run ai-taskbar-validate  # standalone validation suite
make test                      # swift test --no-parallel (Swift Testing)
make coverage                  # swift test + coverage report (no floor)
COVERAGE_FLOOR=90 make coverage  # fail if Core+Providers < 90%
make app                       # release build + assemble .app bundle with ad-hoc sign
make run                       # make app && open it
make dmg                       # make app + hdiutil into ai-taskbar-X.Y.Z.dmg
make validate                  # the policy gate — see above
make clean                     # nuke .build, build/, generated DMGs
```

## Releasing / versioning (automatic on `main`)

**Don't hand-edit version strings to cut a release, and don't push a `v*` tag
yourself for a normal change.** Every push to `main` (typically a PR merge)
triggers `.github/workflows/auto-tag.yml`, which decides the next version,
bumps it everywhere, tags it, and calls `release.yml` — which validates the
tagged commit and creates a **draft** GitHub Release with notes. **CI does NOT
build or attach DMGs** (the Developer ID key stays off the repo on purpose);
the maintainer publishes assets locally with `make publish` (clean-tree +
HEAD-is-tagged guards → builds, signs and notarizes the arm64 AND universal
DMGs → uploads both + checksums → flips draft → published).

- **Bump level** is inferred from commit subjects/bodies since the last `v*`
  tag: `BREAKING CHANGE` / `type!:` / `[bump:major]` → **major**;
  `feat:` / `feat(scope):` / `[bump:minor]` → **minor**; everything else →
  **patch** (the default — this repo's subjects are free-form).
- **Opt out** of a release for a push by putting `[skip release]` anywhere in
  the head commit message (docs-only tweaks, chores). The bump commit the
  workflow itself makes carries this marker so it never recurses.
- **The version lives in four files** kept in lockstep by the workflow:
  `Makefile` (`VERSION`), `Bundler.toml` (`version`), `Resources/Info.plist`
  (`CFBundleShortVersionString` + `CFBundleVersion`), and
  `AboutView.swift` (the `-dev` fallback). If you ever bump by hand, change all
  four together.
- **Manual / pre-release** tags still work: `git tag v0.3.0-beta1 && git push
  origin v0.3.0-beta1` runs `release.yml` directly (pre-release auto-detected
  from the `-` suffix).
- `release.yml` re-runs the runtime validation suite before drafting, but it
  is **not** a substitute for the green `make validate` gate before you push.
- The two DMG names are a contract with `UpdateChecker.pickDMGAsset`:
  `ai-taskbar-X.Y.Z-arm64.dmg` (Apple Silicon) and `ai-taskbar-X.Y.Z.dmg`
  (universal). Renaming either breaks in-app update downloads.

## Architecture (don't break these)

- **`AiTaskbarCore`** — vendor-agnostic. Models, HTTP, Cache, Credentials,
  Config, Cost helpers, History, Util (JSONValue, SharedCoders).
- **`AiTaskbarProviders`** — one file per vendor. All providers use the
  `CachedFetch` helper for the cache → fetch → write → decode → stale fallback
  lifecycle. **Do NOT re-introduce per-provider boilerplate.** If a vendor
  needs special behavior, extend `CachedFetch`, don't fork it.
- **`AiTaskbarApp`** — SwiftUI. `UsageStore` is `@MainActor`. Long-running
  state on `RefreshScheduler` (timer + 24h compactor). Default cadence is
  300 s; the scheduler reads `UsageStore.hasRateLimitedVendor` between
  cycles and adds `RefreshScheduler.rateLimitBackoff` (60 s) to the next
  sleep whenever any vendor's last refresh ended in HTTP 429. Aggregates
  (`maxUtilization`, `isAnyVendorLoading`, `hasRateLimitedVendor`) are
  pre-computed inside `recomputeAggregates()` so the per-second header
  TimelineView reads flat `@Published` properties instead of re-scanning
  vendors. The merged `$state` stream is throttled at 50 ms with
  `Publishers.MergeMany.throttle(latest:true)` to coalesce the bursts of
  synchronous `.loading` → `.ok/.failed` transitions a single
  `refreshAll()` produces. The popover header runs a 1-Hz countdown
  anchored on `UsageStore.lastScheduledTickAt`; localized strings are
  memoized at type init. `DiskCache` TTL is set in `AppEnvironment` to
  `max(15, refresh_interval_seconds − 5)` so the scheduled tick reliably
  trips `freshPayload()` without needing `forceRefresh: true`.
- **`AiTaskbarValidate`** — runtime test runner, see "Validation policy".
- **`AiTaskbarTesting`** — fixtures + StubURLProtocol, shared by tests +
  validate.

## Hard rules

- **Never use `[String: Any]`** for anything that crosses an actor boundary
  or is stored on a `Sendable` type. Use `JSONValue` (in `AiTaskbarCore/Util/`).
- **All files containing secrets must be `0o600`** at write time, not via
  a post-hoc chmod. Use `AtomicFileWrite.write(_, to:, permissions: 0o600)`.
- **All new vendor base_url fields must be host-allowlisted** (see
  `KimiConfig.validate`). User-controlled URLs are an exfil vector.
- **Providers must call `try Task.checkCancellation()`** at fetch entry,
  after OAuth refresh, after the network call, before writing the cache.
- **TOML decoders must use `KeyedDecodingContainer.flexibleDouble` /
  `flexibleDoubleArray`** when expecting a `Double` field. TOML's `70`
  literal parses as `Int64`, not `Double`, and TOMLKit will not auto-cast.
- **Don't swallow errors with `try?`** unless it's truly best-effort (cache
  cleanup, marker writes). If a credential write fails, the user must see it.
- **Keychain reads AND writes** must pass `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`.
  We're an `LSUIElement` menu-bar app, so a SecurityAgent password prompt
  would freeze the refresh cycle behind an invisible window. The only
  tolerated swallow is `errSecInteractionNotAllowed` on `SecItemUpdate` /
  `SecItemAdd` in `KeychainCredentialReader.writeBack` — log via NSLog and
  return (the renewed token still works in memory; the next OAuth cycle
  retries persistence). Every other OSStatus must throw.
- **The shared-credential OAuth providers (Anthropic + OpenAI/Codex) must
  default to read-only credentials.** Both `AnthropicConfig.manageOAuthRefresh`
  and `OpenAIConfig.manageOAuthRefresh` default to `false`, and the providers'
  `manageOAuthRefresh` init params default to `false` too (safe-by-default is
  structural, not applied only at `AppEnvironment.makeProviders`). The app
  shares the `Claude Code-credentials` Keychain item with the Claude Code CLI
  and `~/.codex/auth.json` with the Codex CLI, and **both vendors rotate the
  refresh token on every exchange** — so refreshing here invalidates the token
  other running CLI sessions hold (→ forced re-login), and the Anthropic
  write-back also trips the Keychain ACL prompt on ad-hoc builds. Read-only mode
  reads whatever token the CLI keeps current and lets the CLI own renewal; a
  briefly-expired token serves the last cached snapshot (or surfaces the error
  on a cold cache). Only `manage_oauth_refresh = true` (opt-in, standalone use
  without that CLI) is allowed to call `…OAuth.refresh` + `writeBack`. Do not
  flip the defaults back to `true`. Any future vendor that reads a credential
  shared with a CLI must follow the same read-only-by-default rule.

## Adding a new LLM vendor (checklist)

1. Add case to `VendorId` + `displayName` + `dashboardURL`.
2. Add `XxxSnapshot` to `Models/UsageSnapshot.swift` + extend the discriminator.
3. Add `[xxx]` section to `AppConfig` + add to `ConfigLoader.defaultSnippets`
   so `ensureAllVendorSections` will populate it for existing users.
4. Add `XxxConfig` with `enabled`, `api_key_env`, optional `api_key`, and
   any vendor-specific knobs. URLs MUST be validated.
5. Add `XxxProvider` using `CachedFetch`. Don't duplicate the lifecycle.
6. Add `XxxWireTypes.swift` with lenient (int-or-float) decoders.
7. Add to `PricingTable` if cost tracking applies.
8. Add to `AppEnvironment.makeProviders()`.
9. Add `shortLabel(for:)` case in `MenuBarLabelView` (rotating mode).
10. **Add fixtures + section() to `AiTaskbarValidate/main.swift`** AND a
    **golden test** for the wire type (see "Testing policy" above). Both
    are mandatory — fixtures alone aren't enough to satisfy the
    immutability mandate.
11. Run `make validate` — must pass before commit.
12. Run `COVERAGE_FLOOR=<current floor> make coverage` — new vendor code
    should not drop the % below the active floor.

## Config schema

`~/Library/Application Support/ai-taskbar/config.toml`. Missing sections are
auto-appended on launch by `ConfigLoader.ensureAllVendorSections`, preserving
user edits. See `config.example.toml` for the full schema.

## Known limitations / future work

- Distribution DMGs are signed + notarized **locally** (`make release` /
  `make publish`, credentials via `NOTARY_PROFILE` keychain profile or
  `APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_PASSWORD`). CI deliberately has no signing
  secrets — see "Releasing / versioning".
- v0.2 candidates (open): start-at-login via `SMAppService` works only when
  the `.app` lives in `/Applications`; global hotkey via
  `MenuBarExtraAccess`; OpenAI Platform API (`sk-...`) for actual budget caps.
