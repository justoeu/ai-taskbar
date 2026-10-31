#!/usr/bin/env bash
# wait-for-release-draft.sh <tag> — block until the GitHub release for <tag>
# exists (the draft `release.yml` creates), so `make publish` can upload.
#
# Why: the CI tags first and drafts the release only after re-running the
# validation suite on the tag (~10 min). `make ship` waits for the TAG, then
# builds and notarizes both DMGs; on v0.32.0 that finished before the draft
# existed and `gh release upload` died with "release not found" after the
# whole notarization had been paid for. Polling here, right before the
# upload, keeps the build running in parallel with CI and only waits for
# what is actually missing.
#
# Only gh's "release not found" means "not there yet". Anything else (gh
# missing, logged out, wrong repo, network) fails at once with gh's own
# message: retrying it would turn a clear error into a silent 30 min wait.
#
# Env (overridable so the self-test runs in seconds against a fake gh):
#   GH                    gh command, arguments allowed (default: gh)
#   RELEASE_WAIT_SECONDS  give up after, wall clock    (default: 1800)
#   RELEASE_POLL_SECONDS  between two checks           (default: 20)
set -euo pipefail

TAG=${1:?usage: wait-for-release-draft.sh <tag>}
read -r -a GH_CMD <<< "${GH:-gh}"
WAIT=${RELEASE_WAIT_SECONDS:-1800}
POLL=${RELEASE_POLL_SECONDS:-20}
for pair in "RELEASE_WAIT_SECONDS=$WAIT" "RELEASE_POLL_SECONDS=$POLL"; do
    case "${pair#*=}" in
        ''|*[!0-9]*) echo "✗ ${pair%%=*} must be a whole number of seconds (got '${pair#*=}')" >&2; exit 2 ;;
    esac
done

hint() {
    echo "  the notarized DMGs are kept: once fixed, run make publish-upload" >&2
}

# Wall-clock deadline: counting sleeps alone never advances with POLL=0 and
# ignores the time each gh call takes.
deadline=$((SECONDS + WAIT))
announced=0
while :; do
    if err=$("${GH_CMD[@]}" release view "$TAG" --json tagName --jq .tagName 2>&1 >/dev/null); then
        echo "✓ release $TAG exists"
        exit 0
    fi
    case "$err" in
        *"release not found"*) ;;
        *)
            echo "✗ gh could not look up release $TAG:" >&2
            printf '  %s\n' "${err:-(no output)}" >&2
            hint
            exit 1 ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "✗ release $TAG still missing after ${WAIT}s — check the Auto Tag & Release run in the Actions tab" >&2
        hint
        exit 1
    fi
    if [ "$announced" -eq 0 ]; then
        echo "==> waiting for the CI to draft release $TAG (it validates the tag first)"
        announced=1
    fi
    sleep "$POLL"
done
