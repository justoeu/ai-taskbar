#!/usr/bin/env bash
# scripts/coverage.sh — line-coverage report for AiTaskbarCore + Providers.
#
# Usage:
#   scripts/coverage.sh [floor]
#
# `floor` is a percentage, integer or decimal (90, 91.5). If supplied AND > 0,
# the script exits non-zero when total line coverage falls below it. Pass 0 to
# report only. Anything that is not a plain non-negative number is an error.
#
# Excluded from the calculation:
#   - AiTaskbarApp (SwiftUI views — coverage tooling for `body { ... }` is
#     too noisy without Xcode hosting).
#   - AiTaskbarTesting (test fixtures + stubs).
#   - .build/ checkouts (TOMLKit, swift-testing, etc.).
#   - Tests/ (the tests themselves).

set -euo pipefail
cd "$(dirname "$0")/.."

FLOOR="${1:-0}"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; exit 1; }

# Validate before spending a full test run. The floor used to be tested with
# `[ "$FLOOR" -gt 0 ]`, which errors on "91.5"; inside an `if` that error is
# just "false", so a fractional floor silently meant NO floor and exit 0.
[[ "$FLOOR" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || fail "coverage floor must be a non-negative number (got '$FLOOR')"
ENFORCE=$(awk -v f="$FLOOR" 'BEGIN { print (f + 0 > 0) ? "1" : "0" }')

bold "Running swift test --enable-code-coverage"
# Keep the full log: on failure the summary alone ("failed with 2 issues")
# does not say WHICH test failed, which left a transient failure
# undiagnosable (TEST-MAE-002).
TEST_LOG=$(mktemp -t ai-taskbar-swift-test)
trap 'rm -f "$TEST_LOG"' EXIT
TEST_STATUS=0
swift test --no-parallel --enable-code-coverage >"$TEST_LOG" 2>&1 || TEST_STATUS=$?
grep -E "Test run|fail" "$TEST_LOG" | tail -5 || true
if [ "$TEST_STATUS" -ne 0 ]; then
    bold "Failing tests (swift test exit $TEST_STATUS)"
    # Swift Testing marks every failed test/issue with ✘; XCTest-style and
    # compiler failures use "error:". Fall back to the log tail (e.g. crash).
    if grep -qE "✘|error:" "$TEST_LOG"; then
        grep -E "✘|error:" "$TEST_LOG" | head -100
    else
        tail -40 "$TEST_LOG"
    fi
    fail "swift test failed"
fi

# Ask SwiftPM where THIS toolchain/triple put its build, rather than taking
# the first `find` hit: with a second tree under .build (another arch, a
# stale layout) `head -1` could pair a stale profile or binary with this run.
BIN_PATH=$(swift build --show-bin-path)
PROFDATA="$BIN_PATH/codecov/default.profdata"
BINARY="$BIN_PATH/ai-taskbarPackageTests.xctest/Contents/MacOS/ai-taskbarPackageTests"

if [ ! -f "$PROFDATA" ] || [ ! -f "$BINARY" ]; then
    fail "couldn't find $PROFDATA or $BINARY — did swift test succeed?"
fi

bold "Line coverage — AiTaskbarCore + AiTaskbarProviders"
TOTAL_LINE=$(xcrun llvm-cov report "$BINARY" -instr-profile="$PROFDATA" \
    -ignore-filename-regex='.build|Tests|AiTaskbarApp|AiTaskbarTesting|AiTaskbarValidate|swift-testing|TOMLKit' \
    2>/dev/null \
    | awk '/^TOTAL/ {gsub("%","",$10); print $10}')

if [ -z "$TOTAL_LINE" ]; then
    fail "could not extract coverage % from llvm-cov output"
fi

printf "  Line coverage: \033[1m%s%%\033[0m\n" "$TOTAL_LINE"

# Float-precise comparison so 89.84% doesn't round-down past the 90% gate.
# `awk` is universally available; `bc` isn't on every macOS by default.
BELOW=$(awk -v n="$TOTAL_LINE" -v f="$FLOOR" 'BEGIN { print (n + 0 < f + 0) ? "1" : "0" }')

if [ "$ENFORCE" = "1" ]; then
    if [ "$BELOW" = "1" ]; then
        fail "coverage $TOTAL_LINE% < floor $FLOOR%"
    fi
    ok "coverage $TOTAL_LINE% ≥ floor $FLOOR%"
else
    warn "no floor enforced (COVERAGE_FLOOR=0). Goal: 90%"
fi
