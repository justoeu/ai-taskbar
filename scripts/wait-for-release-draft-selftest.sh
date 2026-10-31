#!/usr/bin/env bash
# Plants a fake `gh` and proves wait-for-release-draft.sh waits for a late
# draft, gives up on a missing one, and fails at once on any other gh error.
# A waiter that returned at once would pass every real ship until the race
# came back. Every case is bounded (wall-clock deadline in the waiter, plus
# an outer watchdog here), so a broken waiter turns this red instead of
# hanging `make validate`.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

cat > "$scratch/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh. Counts calls; MODE=late: `release view` succeeds from call
# $APPEAR_AFTER on (0 = never), else "release not found". MODE=auth: the
# logged-out error. A leading `-R repo` is accepted, as gh does.
count_file="$SCRATCH/calls"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$count_file"
[ "${1:-}" = "-R" ] && shift 2
[ "${1:-} ${2:-}" = "release view" ] || { echo "unexpected: $*" >&2; exit 2; }
if [ "$MODE" = auth ]; then
    echo "To get started with GitHub CLI, please run:  gh auth login" >&2
    exit 4
fi
if [ "$APPEAR_AFTER" -gt 0 ] && [ "$n" -ge "$APPEAR_AFTER" ]; then echo "$3"; exit 0; fi
echo "release not found" >&2
exit 1
FAKE
chmod +x "$scratch/gh"

# run <mode> <appear_after> <wait_seconds> [gh command]
run() {
    rm -f "$scratch/calls"
    SCRATCH="$scratch" MODE="$1" APPEAR_AFTER="$2" GH="${4:-$scratch/gh}" \
        RELEASE_WAIT_SECONDS="$3" RELEASE_POLL_SECONDS=0 \
        "$here/wait-for-release-draft.sh" v9.9.9 >/dev/null 2>&1 &
    local pid=$!
    # Watchdog: nothing here may take longer than its budget plus 5 s.
    ( sleep $(( $3 + 5 )); kill "$pid" 2>/dev/null ) &
    local dog=$!
    local rc=0
    wait "$pid" || rc=$?
    kill "$dog" 2>/dev/null || true
    wait "$dog" 2>/dev/null || true
    return "$rc"
}
calls() { cat "$scratch/calls" 2>/dev/null || echo 0; }
fail() { echo "✗ $*"; exit 1; }

run late 3 3 || fail "waiter failed on a release that appeared late"
[ "$(calls)" = "3" ] || fail "waiter looked $(calls) times at a late release, expected 3"

run late 1 3 || fail "waiter failed on an existing release"
[ "$(calls)" = "1" ] || fail "waiter looked $(calls) times at an existing release, expected 1"

run late 2 3 "$scratch/gh -R owner/repo" || fail "waiter dropped the arguments of a GH override"

if run late 0 1; then fail "waiter succeeded on a release that never appeared"; fi

if run auth 0 3; then fail "waiter succeeded while gh was logged out"; fi
[ "$(calls)" = "1" ] || fail "waiter retried a non-retryable gh error ($(calls) calls)"

if RELEASE_WAIT_SECONDS=soon "$here/wait-for-release-draft.sh" v9.9.9 >/dev/null 2>&1; then
    fail "waiter accepted a non-numeric RELEASE_WAIT_SECONDS"
fi

echo "✓ wait-for-release-draft self-test"
