#!/usr/bin/env bash
# Positive control for the warnings ratchet in validate.sh / ci.yml.
#
# A gate that cannot fail is worse than no gate: it reports success and stops
# anyone from looking. This one shipped broken once — SwiftPM writes compiler
# diagnostics to STDOUT, the check sent stdout to /dev/null and grepped
# stderr, so it printed "0 warnings" unconditionally and two commits landed on
# that number. This script plants a real warning and asserts the detection
# fires, so the next person to touch the pipeline can prove it still works
# instead of assuming.
#
#   ./scripts/warn-ratchet-selftest.sh
#
# Costs one clean build. Not part of `make validate` — run it when you change
# the ratchet.

set -euo pipefail
cd "$(dirname "$0")/.."

KEYCHAIN_LEGACY='Credentials/(KeychainAccessAuthorizer|KeychainCredentialReader|KeychainPromptSuppressor)\.swift'
PLANT="Sources/AiTaskbarCore/__WarnRatchetSelfTest.swift"

cleanup() { rm -f "$PLANT"; }
trap cleanup EXIT

count_other() {
    local scratch log
    scratch=$(mktemp -d)
    # 2>&1 — the whole point. See the comment block in validate.sh.
    swift build --build-tests --scratch-path "$scratch" >"$scratch/w.log" 2>&1 || true
    log="$scratch/w.log"
    grep -oE "Sources/[^ ]+\.swift:[0-9]+:[0-9]+: warning:" "$log" 2>/dev/null \
        | sort -u | grep -vcE "$KEYCHAIN_LEGACY" || true
    rm -rf "$scratch"
}

echo "[1/2] baseline (no planted warning) — expect 0 outside the allowlist"
base=$(count_other)
echo "      got: ${base:-0}"
if [ "${base:-0}" -ne 0 ]; then
    echo "  ✗ baseline is already dirty; fix the tree before trusting this test"
    exit 1
fi

echo "[2/2] planting a warning — expect the ratchet to see it"
cat > "$PLANT" <<'SWIFT'
// Temporary file written by scripts/warn-ratchet-selftest.sh.
// `var` never mutated -> guaranteed compiler warning.
enum __WarnRatchetSelfTest {
    static func plant() -> Int {
        var unused = 1
        return unused
    }
}
SWIFT
planted=$(count_other)
cleanup
echo "      got: ${planted:-0}"

if [ "${planted:-0}" -lt 1 ]; then
    echo "  ✗ RATCHET IS BLIND — it did not see a planted warning."
    echo "    Most likely the stream redirection regressed: SwiftPM writes"
    echo "    diagnostics to stdout, so the build must be captured with 2>&1."
    exit 1
fi

echo "  ✓ ratchet detects planted warnings (baseline 0, planted ${planted})"
