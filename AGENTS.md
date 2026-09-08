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

Enforce with `COVERAGE_FLOOR=90 make validate` (default in `Makefile` and
`scripts/validate.sh`). **Hard fail at 90%** in CI and local `make validate`.
Override only for local experiments (`COVERAGE_FLOOR=0 make coverage`).

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
- **Keep the Boolean assertion guards introduced for the former mixed
  Apple Swift 6.3.2 / standalone Testing 0.99.0 stack.** Every one of these
  PASSED with a value that made it false on that stack — verified by running
  them, not inferred:

  ```swift
  #expect(false == true)                                 // passes (!)
  let x: Bool? = false; #expect(x ?? false)               // passes (!)
  let x: Bool? = true;  #expect(x == Optional(false))     // passes (!)
  let x: Bool? = true;  #expect(x.map { !$0 } ?? false)   // passes (!)
  ```

  and one was inverted outright: `#expect(!(x ?? true))` **failed** for
  `x == .some(false)`, where plain Swift evaluates the same expression to
  `true`. This was found because 43 asserts across 16 files were written the
  `== true` way and none of them could ever fail; fixing them surfaced a real
  dead-code bug in `ClaudeSessionScanner` that had been invisible for months.

  **Rule:** for any condition involving an optional, use `expectTrue` /
  `expectFalse` from the shared `Sources/AiTaskbarTestSupport/ExpectBool.swift`
  file. They take a plain `Bool`
  *parameter*, so the condition is evaluated as ordinary Swift at the call
  site and the macro only ever sees a bare identifier. A non-optional
  `#expect(flag)` / `#expect(!flag)` is safe, and so are non-`Bool`
  comparisons (`#expect(3 == 4)` and `#expect(s == "b")` fail correctly).
  `scripts/validate.sh` fails the build on any known-vacuous form.
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

### 5. Zero warnings outside classic-Keychain deprecations

`scripts/validate.sh` and CI share `scripts/check-swift-warnings.sh`, covering
source, test, macro-expansion and linker diagnostics. Only deprecations in
`Sources/AiTaskbarCore/Credentials/Keychain{AccessAuthorizer,CredentialReader,PromptSuppressor}.swift`
and their isolated-keychain test fixtures (`KeychainAccessAuthorizerTests.swift`,
`KeychainCredentialReaderTests.swift`, `TemporaryKeychain.swift` in
`Tests/AiTaskbarCoreTests/`) are allowlisted. Other warnings in those files fail
too. The fixtures exercise the same unavoidable classic API; previously all
test warnings were accidentally excluded by a Sources-only matcher.
Both measure with a **clean** build (`--scratch-path` to a temp dir): an
incremental build recompiles nothing and reports zero no matter how bad things
are.

Two things this bar encodes, both learned by getting them wrong:

- **The legacy-keychain deprecations are unavoidable.** `SecKeychain*`,
  `SecACL*` and `kSecUseAuthenticationUI` are the only route to classic
  file-keychain ACLs, and Swift has no per-call suppression. Annotating the
  enclosing function `@available(macOS, deprecated:)` was tried and **reverted**
  — it silences the call *into* the C API but makes every caller of the
  annotated function warn instead, turning one warning into four. Allowlisting
  is honest; annotating was cosmetics that made it worse.
- **The check must capture STDOUT.** SwiftPM writes compiler diagnostics to
  stdout, not stderr. The first version of this ratchet sent stdout to
  `/dev/null` and grepped stderr, so it reported "0 warnings" unconditionally
  and could not fail — two commits landed on that number, including one whose
  message claimed a clean tree. `scripts/warn-ratchet-selftest.sh` plants a
  warning and asserts the gate catches it; run it whenever you touch the
  pipeline. A gate that cannot fail is worse than no gate, because it stops
  anyone from looking.

The failure mode being guarded against is not "a warning appeared" but
"warnings piled up until nobody read them": the `swift-testing` package was
emitting a deprecation on every `@Test`/`@Suite` — hundreds — which is how a
double-optional bug in `AppConfig.flexibleDoubleIfPresent` and a non-Sendable
capture in `NotificationService` sat in plain sight.

Two conventions came out of that cleanup:

- **Use only toolchain-bundled Testing.** Neither `swift-testing` nor its
  transitive `swift-syntax` belongs in the package dependency graph. Mixing
  the package with toolchain macros caused ignored assertions, warnings and,
  with standalone 6.3.2, linker failures. The former regular
  `AiTaskbarTestSupport` target could not import bundled Testing on CLT.
  Its canonical `Sources/AiTaskbarTestSupport/ExpectBool.swift` is now compiled
  directly by each test target through a relative `ExpectBool.swift` symlink;
  preserve those three links and do not add a production dependency on Testing.
  `TestingInfrastructureTests` pins the remaining dependency and verifies that
  false helper assertions reach the runner. After removing old package modules,
  run `swift package clean` before validation. The app still targets macOS 13;
  tests require full Xcode and the minimum macOS supported by its Testing
  framework. CLT 6.3.2 has broken framework/runtime discovery for bundled
  Testing. `make test`, `make coverage` and `make validate` use
  `scripts/with-test-toolchain.sh`: preserve explicit `DEVELOPER_DIR` or the
  selected full Xcode; otherwise use `/Applications/Xcode.app` if installed.
  Invalid explicit selections fail without fallback. No global `xcode-select`
  change or SDK/linker-path workaround is allowed. Direct `swift test` and
  warning self-tests must run with a full-Xcode `DEVELOPER_DIR` too.
- **Don't reach for `@available(deprecated:)` to hide a warning you could fix.**
  See above for why it usually doesn't even hide it.

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
the maintainer publishes assets locally with `make ship` (push → wait for the
CI tag → pull the bump → `make publish`, which enforces clean-tree +
HEAD-is-tagged guards, builds, signs and notarizes the arm64 AND universal
DMGs, uploads both + checksums, and flips draft → published). `ship` aborts
cleanly on `[skip release]` heads.

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

### DMG release runbook (generating the signed DMG)

The `.app` and both DMGs are built, signed, **notarized** and published
**locally** — CI only tags + drafts. To cut a release from a clean `main`:

1. **One-time setup.** Store an app-specific password (generated at
   account.apple.com → Sign-In & Security → App-Specific Passwords) as a
   notarytool keychain profile so it never touches env vars or shell history:
   ```bash
   xcrun notarytool store-credentials "ai-taskbar-notary" \
     --apple-id you@example.com --team-id 5HHL78743R --password <app-specific-pw>
   ```
   Verify: `xcrun notarytool history --keychain-profile ai-taskbar-notary`.
   The Developer ID identity (`Developer ID Application: Valmir Robson Justo
   (5HHL78743R)`) must already be in the login keychain — check with
   `security find-identity -v -p codesigning`.

   Storing a profile types an Apple ID and an app-specific password, so it is
   the maintainer's step, not the agent's. **But check before asking anyone to
   do it, and check by USING the profile** — `xcrun notarytool history
   --keychain-profile <name>`. A keychain query
   (`security find-generic-password -s "com.apple.gke.notary.tool"`) returns
   nothing even when working profiles exist; on 2026-07-25 that false negative
   produced a confident "notarization is blocked" and a pointless request to
   re-run `store-credentials`, when `ai-taskbar-notary` and `ai-taskbar` had
   both been working since July 2nd. Absence of evidence from the wrong query
   is not evidence of absence.

   `DEVELOPER_ID` is auto-detected when the keychain holds exactly one
   `Developer ID Application` certificate, so you normally do not pass it. With
   two or more it stays unset on purpose — picking one silently could sign a
   release under the wrong team.
2. **Gate.** `make validate` must be green **and** the tree must be clean
   (commit/stash first — `make publish` refuses a dirty tree or an untagged
   HEAD).
3. **Ship.** One command does push → wait for the CI tag → pull the bump →
   build → sign → notarize → staple → upload → flip draft to published:
   ```bash
   make ship DEVELOPER_ID="Developer ID Application: Valmir Robson Justo (5HHL78743R)" \
             NOTARY_PROFILE="ai-taskbar-notary"
   ```
   (Or `export` both first.) `APPLE_ID` + `APPLE_TEAM_ID` + `APPLE_PASSWORD`
   work in place of `NOTARY_PROFILE`.

Related targets: `make publish` is the second half alone (tag already exists
locally); `make release` builds + notarizes both DMGs without uploading;
`make dmg` is an unsigned ad-hoc local build for testing only.

**Publishing a tag that `main` has already moved past.** `make publish` requires
`HEAD` to carry the `v$(VERSION)` tag, so once any commit lands on `main` after
the bump, publishing from `main` refuses. Check out the tag instead — the tree
is clean and `HEAD` carries it, which is all the guard wants:

```bash
git checkout v0.16.1 && make publish && git checkout main
```

**Where releases actually go wrong** (each of these has happened):

| Symptom | Cause | Now |
|---|---|---|
| `DEVELOPER_ID not set` after a 3-minute build | `publish` had no up-front guard and `DEVELOPER_ID` had no default, while `APP_SIGN_IDENTITY` auto-detected the same certificate one line above | auto-detected when unambiguous; `publish` checks signing + notarization credentials in its first second |
| Release job fails on a tag that CI passed | `ci.yml` and `release.yml` selected Swift independently and drifted (6.2.4 vs 6.0) | both call `.github/actions/select-swift`, which requires >= 6.2 |
| Universal DMG that is arm64-only | `make dmg` writes a host-arch app to `$(DMG)`, the universal name `UpdateChecker.pickDMGAsset` serves to Intel Macs | `universal-check` asserts x86_64 + arm64 and gates `release-universal` |
| Release notes missing the actual feature | the changelog spans previous-tag..this-tag; a tag that never produced a release swallows everything before it | regenerate with `gh release edit <tag> --notes-file` over the right range |

**Doc-only commits pushed to `main` MUST carry `[skip release]`** — otherwise
they trigger a redundant version bump (this is how an accidental extra
`v0.10.1` got cut alongside `v0.10.0`).

## Architecture (don't break these)

- **`AiTaskbarCore`** — vendor-agnostic. Models, HTTP, Cache, Credentials,
  Config, Cost helpers, History, Util (JSONValue, SharedCoders).

### Cost scanners — token semantics differ per source, do not generalize

Each scanner reads a different vendor's local records, and the same-sounding
fields do not mean the same thing. Copying an assumption from one into another
produces numbers that are wrong by multiples while looking plausible:

| | `input` includes cached? | reasoning tokens |
|---|---|---|
| `CodexSessionScanner` (`~/.codex/sessions`) | **yes** — cached is subtracted out | folded into output |
| `OpencodeScanner` (`~/.local/share/opencode/opencode.db`) | **no** — carried across as-is | **separate field**, added to output |

Both were established against real data, not documentation, and both are pinned
by tests that fail if the other reading is applied. `OpencodeScanner` reads
per-MESSAGE, never `session.model` — that column holds the last model a session
used, so session-level attribution files every pre-switch token under the wrong
model (measured: ~20M tokens on this machine).

opencode is a **client, not a vendor**. Its usage is attributed to whichever
vendor billed it and is never merged into that vendor's own totals: OpenAI
traffic rides a subscription (zero marginal cost, so tokens are shown and
dollars are not), and xAI's card already reports account-wide cycle spend from
the Management API, so adding opencode's dollars there would double-count.
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
  vendors. **`maxUtilization` only folds vendors whose popover card is
  expanded (open)** — a collapsed (closed) card is excluded from the menu-bar
  percentage. The source of truth for that is `VendorViewModel.isExpanded`
  (seeded from UserDefaults key `expanded_<vendor>`, default open), NOT a
  view-local `@State`, precisely so the aggregate can read it. The `loading`
  and `rate-limited` flags still consider every vendor regardless of expand
  state (they drive the countdown + scheduler back-off). The merged stream
  now merges both `$state` and `$isExpanded` (erased to `Void`), throttled at
  50 ms with `Publishers.MergeMany.throttle(latest:true)` to coalesce the
  bursts of synchronous `.loading` → `.ok/.failed` transitions a single
  `refreshAll()` produces and to recompute the % when a card is toggled. The popover header runs a 1-Hz countdown
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
- **Keychain reads AND writes** must run inside
  `KeychainPromptSuppressor.withPromptsSuppressed` AND pass
  `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`. UIFail alone only
  suppresses the trusted-app Allow/Deny confirmation; the **partition-list
  password dialog ignores it** (verified via securityd `kcacl` logs +
  two-binary probe on macOS 26) and only
  `SecKeychainSetUserInteractionAllowed(false)` blocks it. We're an
  `LSUIElement` menu-bar app, so a SecurityAgent password prompt would
  freeze the refresh cycle behind an invisible window — and visibly spam
  the user on every `make validate` smoke launch. Under suppression an
  ACL-blocked op fast-fails with `errSecInteractionNotAllowed` (-25308) or
  `errSecAuthFailed` (-25293) — treat BOTH as ACL-blocked
  (`KeychainCredentialReader.isACLBlockedStatus`); they drive the Authorize
  banner. The only tolerated swallow is those two codes on `SecItemUpdate` /
  `SecItemAdd` in `KeychainCredentialReader.writeBack` — log and return (the
  renewed token still works in memory; the next OAuth cycle retries
  persistence). Every other OSStatus must throw. The single intentional
  prompt in the app — `KeychainAccessAuthorizer.authorize`'s exact-item read —
  must run inside `withPromptsAllowed` ONLY after the user clicks Authorize,
  with `kSecUseAuthenticationUIAllow`. This user-approved exception never
  applies to scheduled reads or writes. Require a silent read of the same
  item afterward; do not report persistent authorization from an interactive
  success alone. Do not capture the Keychain password or execute shell ACL commands.
  **One read-only exception:** when the direct read fast-fails with either
  ACL code, `KeychainCredentialReader` retries the *same item* through
  `SecurityToolCredentialReader` (`/usr/bin/security find-generic-password -s
  <service> -a <account> -w`). The Claude Code CLI writes the item with that
  tool, so the tool is on its trusted-app list and `apple-tool:` partition no
  matter how this binary is signed — which is what made ad-hoc dev builds
  re-prompt after every rebuild (36 dead `cdhash` grants on one machine).
  Rules: exact-match arguments only (`-s` is exact, verified), stdin
  `/dev/null`, stderr discarded, payload never logged, 10 s timeout that kills
  the child (dismissing any dialog securityd raised for it) and then a 1 h
  cooldown, and **never for writes** — `writeBack` stays `SecItemUpdate`. When
  the fallback fails the original ACL error is rethrown so the Authorize
  banner still appears.
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
- **Gemini is API-key heartbeat only — no usage/cost integration is feasible
  today** (see README "Google Gemini — limited"). The consumer Gemini app
  subscription (Plus/Pro/Ultra) has no public usage API; the developer
  Cloud Monitoring API measures GCP-project API requests, not the
  subscription; Code Assist's `cloudcode-pa…v1internal:retrieveUserQuota`
  (read from `~/.gemini/oauth_creds.json`) works but is undocumented and is
  being retired for individuals on 2026-06-18; the Antigravity CLI (`agy`)
  exposes no usage command and stores auth as encrypted Electron
  cookies/safeStorage. Revisit only if Google ships a real OAuth usage API.
  Do NOT build against `v1internal` or scrape Electron cookies.
- **TOMLKit is the single runtime dependency and is effectively unmaintained**
  (no release in ~2.5 years, no commits in ~18 months, pinned at 0.6.0 in
  `Package.resolved`). **Accepted residual risk** (ultra-deep DEP-PRI-001):
  it parses a local config file we write the schema for, has no network
  surface, and the pin is reproducible. Migration risk only — if it stops
  building on a future Swift, vendor the ~2k lines we use or hand-roll the
  small TOML subset `AppConfig` needs. Re-evaluate on Swift major; don't
  swap preemptively.
- **`codex-auto-review` is priced by estimate.** Codex writes that model alias
  to its rollout logs for the automatic review pass, and OpenAI publishes no
  rate for it, so `PricingTable.openai` carries it at the Codex flagship tier
  (`gpt-5.3-codex`, $1.75/$14). It is not a negligible slice — on a real 7-day
  window it was ~6% of the Codex total. Replace with published numbers when
  they exist; do NOT drop the entry, since a missing key prices every review
  turn at $0.
- v0.2 candidates (open): start-at-login via `SMAppService` works only when
  the `.app` lives in `/Applications`; global hotkey via
  `MenuBarExtraAccess`; OpenAI Platform API (`sk-...`) for actual budget caps.
