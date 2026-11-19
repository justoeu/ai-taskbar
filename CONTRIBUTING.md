# Contributing to AI Taskbar

The rules that bind every change — the validation gate, the testing policy and
the architecture invariants — live in [CLAUDE.md](CLAUDE.md). This file is the
practical guide: how to build, test and release.

## Ground rules

1. Run `make validate` before every commit and PR — the gate has to be green.
2. New vendor → follow the checklist in [CLAUDE.md](CLAUDE.md) ("Adding a new LLM vendor").
3. New strings → add to all three `.lproj/Localizable.strings` files (en, pt-BR, es).
4. Architectural changes → update [CLAUDE.md](CLAUDE.md) in the same PR.
5. Doc-only commits pushed to `main` carry `[skip release]`.

## Toolchain

The app targets macOS 13+ and needs Swift 6.2+. Use **full Xcode**: tests need
the Testing framework bundled with it, and with the macOS 27.2 SDK the Command
Line Tools lack the SwiftUI macro plugin, so release builds fail there with
errors like `cannot find '$x' in scope`. `make test`, `make coverage` and
`make validate` pick `/Applications/Xcode.app` on their own; for release
targets, prefix `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
while `xcode-select` points at the Command Line Tools. Never change the
global `xcode-select` for this.

## Build commands

```bash
make app                # debug-quality release build, host arch (fast iteration)
make app-universal      # arm64 + x86_64 fat binary
make icon               # regenerate Resources/AppIcon.icns from the Swift drawing script (manual; commit the result — builds use the committed icon)
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

## Dependencies and testing

TOMLKit **0.6.0** is the only SwiftPM dependency; its embedded toml++ is **3.4.0**. Both remain at their latest published stable releases as checked on 2026-09-06. Tests use **Testing bundled with the selected Swift toolchain**, not a separately versioned `swift-testing` or `swift-syntax` package. This avoids mixing incompatible Testing runtimes and macros. See the [upstream distribution guidance](https://github.com/swiftlang/swift-testing/blob/main/Documentation/Distributions.md).

The Boolean assertion helpers have one canonical source at `Sources/AiTaskbarTestSupport/ExpectBool.swift`, compiled directly in each test target through relative symlinks. Keep those symlinks intact. Negative-control tests verify that deliberately false helper assertions are observed by the runner. After migrating an existing checkout, run `swift package clean` once before `make validate` to discard modules built against the former standalone package.

`make test`, `make coverage` and `make validate` preserve an explicit `DEVELOPER_DIR` or the selected full Xcode. When only CLT is selected, they use `/Applications/Xcode.app` if installed. This does not change the machine's global `xcode-select` setting or release commands. For another Xcode location, use `DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer make validate`. For direct `swift test` commands, select the full Xcode with the same environment variable.

## Customize bundle identifier

```bash
make BUNDLE_ID=com.yourorg.aitaskbar app
```

## Code-signed distribution (optional, requires paid Apple Developer ID)

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

Result: a DMG that opens with **no Gatekeeper warnings** on any macOS 11+ Mac. Without this, you get the one-time warning described in the [README](README.md#install).

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
`ai-taskbar-X.Y.Z.dmg` — uploads both plus a `checksums-X.Y.Z.txt`, checks that the release now lists
all three (`make release-assets-check`), and only then flips the release from
draft to published. The in-app update checker picks the DMG
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
AiTaskbarProviders/       one file per provider — all use CachedFetch + OAuthRefresher
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
