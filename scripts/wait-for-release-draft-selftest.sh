#!/usr/bin/env bash
# Plants a fake `gh` and proves wait-for-release-draft.sh both waits for a
# release that appears late and gives up on one that never does. A waiter
# that returned at once would pass every real ship until the race came back.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

cat > "$scratch/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh: `release view` succeeds only from call number $APPEAR_AFTER on.
count_file="$SCRATCH/calls"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$count_file"
[ "$1 $2" = "release view" ] || exit 2
[ "$APPEAR_AFTER" -gt 0 ] && [ "$n" -ge "$APPEAR_AFTER" ] && { echo "$3"; exit 0; }
echo "release not found" >&2
exit 1
FAKE
chmod +x "$scratch/gh"

run() {
    rm -f "$scratch/calls"
    SCRATCH="$scratch" APPEAR_AFTER="$1" GH="$scratch/gh" \
        RELEASE_WAIT_SECONDS="$2" RELEASE_POLL_SECONDS=0 \
        "$here/wait-for-release-draft.sh" v9.9.9 >/dev/null 2>&1
}
calls() { cat "$scratch/calls"; }

# Appears on the 3rd look: must wait, then succeed.
if ! run 3 5; then echo "✗ waiter failed on a release that appeared late"; exit 1; fi
[ "$(calls)" = "3" ] || { echo "✗ waiter looked $(calls) times, expected 3"; exit 1; }

# Already there: one look, success.
run 1 5 || { echo "✗ waiter failed on an existing release"; exit 1; }
[ "$(calls)" = "1" ] || { echo "✗ waiter looked $(calls) times at an existing release"; exit 1; }

# Never appears: must give up with a non-zero exit.
if run 0 0; then echo "✗ waiter succeeded on a release that never appeared"; exit 1; fi

echo "✓ wait-for-release-draft self-test"
