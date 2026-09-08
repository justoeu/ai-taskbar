#!/usr/bin/env bash
# scripts/validate.sh — full local validation suite.
# Runs after EVERY implementation change. See CLAUDE.md / AGENTS.md.
#
# Steps (fail-fast):
#   1. swift build -c debug         — catches compile errors
#   2. swift run ai-taskbar-validate — runtime suite, 67+ assertions
#   3. make app                      — assembles .app bundle
#   4. quick launch + kill           — proves Mach-O loads under macOS
#   5. permission audit              — credential files locked to 0o600
#
# Exits non-zero on any failure. Designed to run in CI as-is.

set -euo pipefail
cd "$(dirname "$0")/.."

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; exit 1; }

# Coverage gate. Hard-fail under this percentage. Override with
# Hard floor 90% on Core+Providers (CI + local). Override only for experiments.
COVERAGE_FLOOR="${COVERAGE_FLOOR:-90}"

bold "[1/6] swift build"
swift build -c debug 2>&1 | tail -3
ok "compile clean"

bold "[2/6] runtime validation suite"
swift run ai-taskbar-validate
ok "67+ assertions passed"

bold "[3/6] swift test + coverage"
COVERAGE_FLOOR="$COVERAGE_FLOOR" scripts/coverage.sh "$COVERAGE_FLOOR"

bold "[4/6] assemble .app bundle"
make app >/dev/null 2>&1
test -x build/AiTaskbar.app/Contents/MacOS/ai-taskbar || fail "Mach-O missing"
codesign --verify build/AiTaskbar.app 2>/dev/null || fail "ad-hoc signature invalid"
# Bundle.module crashes the popover if the SPM-generated resource bundle is
# in the wrong location (regression from v0.1.0). Must live in Resources/.
spm_bundle="build/AiTaskbar.app/Contents/Resources/ai-taskbar_AiTaskbarApp.bundle"
test -d "$spm_bundle" \
    || fail "SPM resource bundle missing from Contents/Resources/ — Bundle.module will fatalError"
test -f "$spm_bundle/en.lproj/Localizable.strings" \
    || fail "Localizable.strings missing from resource bundle"
ok "bundle + ad-hoc signature OK"

bold "[5/6] smoke launch"
pkill -f "build/AiTaskbar.app" 2>/dev/null || true
sleep 1
# Exec the Mach-O directly instead of `open`: dev builds are signed with the
# same Developer ID identity + bundle id as the installed /Applications app,
# and LaunchServices resolves `open build/AiTaskbar.app` (even with -n) to
# the registered/running installed copy — the dev binary never launches and
# the aliveness check reads as a false "app died". Direct exec still loads
# the full SwiftUI MenuBarExtra runtime, which is what this step proves.
build/AiTaskbar.app/Contents/MacOS/ai-taskbar &
smoke_pid=$!
sleep 3
if kill -0 "$smoke_pid" 2>/dev/null; then
    ok "app launched and stayed alive 3s"
    kill "$smoke_pid" 2>/dev/null || true
else
    fail "app died within 3s — check Console.app for crash"
fi

bold "[6/6] permission audit"
support_dir="$HOME/Library/Application Support/ai-taskbar"
config_file="$support_dir/config.toml"
codex_auth="$HOME/.codex/auth.json"

if [ -d "$support_dir" ]; then
    perm=$(stat -f "%Lp" "$support_dir")
    [ "$perm" = "700" ] && ok "Application Support dir 0700" || fail "support dir $perm (expected 700)"
fi
if [ -f "$config_file" ]; then
    perm=$(stat -f "%Lp" "$config_file")
    [ "$perm" = "600" ] && ok "config.toml 0600" || fail "config.toml $perm (expected 600)"
fi
if [ -f "$codex_auth" ]; then
    perm=$(stat -f "%Lp" "$codex_auth")
    [ "$perm" = "600" ] && ok "~/.codex/auth.json 0600" || fail "codex auth $perm (expected 600)"
fi

# The Anthropic reader may exec /usr/bin/security as a read-only fallback for
# an ACL-blocked Keychain item. Pin the binary we exec: Apple-signed and
# root-owned, so the credential never flows through a substitutable tool.
sec_tool=/usr/bin/security
[ "$(stat -f '%Su' "$sec_tool")" = "root" ] || fail "$sec_tool is not root-owned"
codesign --verify -R='anchor apple' "$sec_tool" 2>/dev/null || fail "$sec_tool is not Apple-signed"
ok "/usr/bin/security root-owned + Apple-signed"

bold "[7/7] doc mirror + assert sanity"
# CLAUDE.md and AGENTS.md are the same document for two different agents.
# They were byte-identical for the project's whole history until an edit
# landed in one only — and AGENTS.md is what the Codex CLI reads, so the
# divergence silently hid guidance written FOR that agent. Convention alone
# didn't hold it; this does.
if ! cmp -s CLAUDE.md AGENTS.md; then
    fail "CLAUDE.md and AGENTS.md diverged — run: cp CLAUDE.md AGENTS.md"
fi
ok "CLAUDE.md ≡ AGENTS.md"

# The former mixed Swift 6.3.2 / standalone Testing 0.99.0 stack
# mis-evaluated Bool sub-expressions. These forms all PASSED when false —
# verified by running them, not by reading the macro:
#
#   #expect(false == true)                    #expect(opt ?? false)
#   #expect(opt == Optional(false))           #expect(opt.map { !$0 } ?? false)
#
# and `#expect(!(opt ?? true))` is inverted outright: it FAILS where plain
# Swift evaluates the same expression to true. An assert written any of these
# ways defends nothing. Use expectTrue/expectFalse from AiTaskbarTestSupport,
# which take a plain Bool parameter so the condition is evaluated as ordinary
# Swift before the macro sees it. Bare `#expect(flag)` / `#expect(!flag)` on a
# non-optional Bool is fine, as are non-Bool comparisons.
vacuous_re='#expect\((.*== *(true|false)\)|.*\?\? *(true|false)\)|.*== *Optional\()'
# `|| true` is load-bearing under `set -o pipefail`: grep exits 1 when it finds
# nothing, which is the PASSING case here and would otherwise abort the script.
vacuous=$(grep -rnE "$vacuous_re" Tests/ 2>/dev/null | wc -l | tr -d ' ' || true)
if [ "${vacuous:-0}" -gt 0 ]; then
    grep -rnE "$vacuous_re" Tests/ | head -5 || true
    fail "$vacuous vacuous #expect form(s) — use expectTrue/expectFalse (AiTaskbarTestSupport)"
fi
ok "no vacuous #expect forms"

# Warnings ratchet.
#
# Measured on a CLEAN build (--scratch-path to a temp dir): an incremental
# build recompiles nothing and reports zero no matter how bad things are.
#
# `2>&1` is load-bearing. SwiftPM writes compiler diagnostics to STDOUT, not
# stderr — an earlier version of this check sent stdout to /dev/null and
# grepped stderr, so it reported "0 warnings" unconditionally and could not
# fail. Two commits were landed on the strength of that number. If you touch
# this, re-run the positive control in `scripts/warn-ratchet-selftest.sh`,
# which plants a warning and asserts the gate catches it.
#
# The bar is "zero warnings OUTSIDE the legacy-keychain files", not "zero".
# The `SecKeychain*` / `SecACL*` / `kSecUseAuthenticationUI` deprecations are
# unavoidable — they are the only route to classic file-keychain ACLs (see
# KeychainAccessAuthorizer's type doc) and Swift has no per-call suppression.
# Marking the enclosing functions `@available(deprecated:)` was tried and
# REVERTED: it silences the call *into* the C API but makes every caller of
# the annotated function warn instead, turning one warning into four.
warn_scratch=$(mktemp -d)
if ! swift build --build-tests --scratch-path "$warn_scratch" >"$warn_scratch/w.log" 2>&1; then
    tail -40 "$warn_scratch/w.log"
    rm -rf "$warn_scratch"
    fail "clean warning-check build failed"
fi
if ! scripts/check-swift-warnings.sh "$warn_scratch/w.log"; then
    rm -rf "$warn_scratch"
    fail "compiler warnings outside the legacy-Keychain deprecation allowlist"
fi
rm -rf "$warn_scratch"
ok "0 warnings outside legacy Keychain (including tests and macros)"

echo
bold "✓ All validations passed."
