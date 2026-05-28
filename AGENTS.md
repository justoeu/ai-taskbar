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
2. `swift run ai-taskbar-validate` — **67+ runtime assertions** in
   `Sources/AiTaskbarValidate/main.swift`. Covers: wire-type fixtures for
   every vendor, OAuth error parsing, JWT decode, AppError equality,
   JSONValue round-trip, KimiConfig URL validation, DiskCache TTL+stale
   semantics, AtomicFileWrite permissions, ConfigLoader TOML int↔double
   tolerance, UsageHistoryStore append/load/compact, PricingTable, CostMath.
3. `make app` — assembles the `.app` bundle with ad-hoc code signature.
4. **Smoke launch** — `open build/AiTaskbar.app`, waits 3 s, confirms
   process is still alive, then kills it. Proves the Mach-O actually loads
   under SwiftUI's MenuBarExtra runtime.
5. **Permission audit** — verifies `~/Library/Application Support/ai-taskbar/`
   is `0700`, `config.toml` is `0600`, `~/.codex/auth.json` is `0600`.
   These hold credentials; loose perms are a security regression.

If any step fails, **fix it before claiming the work is done**. Don't paper
over with comments or `try?`-swallowing.

## Adding new tests

When you implement anything new:

- **Pure logic** (decoders, helpers, cost math, config) → add a `section(...)`
  block to `Sources/AiTaskbarValidate/main.swift`. Keep assertions atomic
  (one fact per `expect`) so failures point exactly at the broken invariant.
- **New vendor wire types** → add a fixture string to
  `Sources/AiTaskbarTesting/Fixtures.swift` first, then assert against it
  in the validate target.
- **New security surface** (e.g. another inline secret in config) → add
  a permission check to `scripts/validate.sh`.
- **UI-only changes** that can't be asserted on headlessly → at minimum
  exercise them via the smoke launch and document in the PR what was
  visually verified.

XCTest in `Tests/` is kept for the day full Xcode is available. Do NOT delete
those tests; the validation suite mirrors and extends them.

## Build commands

```bash
swift build                    # debug build, all targets
swift run ai-taskbar           # run app from .build (no .app bundle, will Dock-icon)
swift run ai-taskbar-validate  # standalone validation suite
make app                       # release build + assemble .app bundle with ad-hoc sign
make run                       # make app && open it
make dmg                       # make app + hdiutil into ai-taskbar-X.Y.Z.dmg
make validate                  # the policy gate — see above
make clean                     # nuke .build, build/, generated DMGs
```

## Architecture (don't break these)

- **`AiTaskbarCore`** — vendor-agnostic. Models, HTTP, Cache, Credentials,
  Config, Cost helpers, History, Util (JSONValue, SharedCoders).
- **`AiTaskbarProviders`** — one file per vendor. All providers use the
  `CachedFetch` helper for the cache → fetch → write → decode → stale fallback
  lifecycle. **Do NOT re-introduce per-provider boilerplate.** If a vendor
  needs special behavior, extend `CachedFetch`, don't fork it.
- **`AiTaskbarApp`** — SwiftUI. `UsageStore` is `@MainActor`. Long-running
  state on `RefreshScheduler` (timer + 24h compactor).
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
10. **Add fixtures + section() to `AiTaskbarValidate/main.swift`.** This is
    not optional.
11. Run `make validate` — must pass before commit.

## Config schema

`~/Library/Application Support/ai-taskbar/config.toml`. Missing sections are
auto-appended on launch by `ConfigLoader.ensureAllVendorSections`, preserving
user edits. See `config.example.toml` for the full schema.

## Known limitations / future work

- App is ad-hoc signed only. Gatekeeper warns on first launch. Notarization
  needs an Apple Developer account ($99/yr) — deferred.
- XCTest tests require full Xcode. Validate suite is the day-to-day cover.
- v0.2 candidates (open): start-at-login via `SMAppService` works only when
  the `.app` lives in `/Applications`; global hotkey via
  `MenuBarExtraAccess`; OpenAI Platform API (`sk-...`) for actual budget caps.
