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
# COVERAGE_FLOOR=<n>. The 90 target lives in CLAUDE.md / AGENTS.md.
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

echo
bold "✓ All validations passed."
