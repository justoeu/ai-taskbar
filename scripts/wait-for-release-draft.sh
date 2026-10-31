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
# Env (overridable so the self-test runs in seconds against a fake gh):
#   GH                    gh binary              (default: gh)
#   RELEASE_WAIT_SECONDS  give up after          (default: 1800)
#   RELEASE_POLL_SECONDS  between two checks     (default: 20)
set -euo pipefail

TAG=${1:?usage: wait-for-release-draft.sh <tag>}
GH=${GH:-gh}
WAIT=${RELEASE_WAIT_SECONDS:-1800}
POLL=${RELEASE_POLL_SECONDS:-20}

waited=0
announced=0
while :; do
    # Any failure (not found yet, a network blip) means "not there yet".
    if "$GH" release view "$TAG" --json tagName --jq .tagName >/dev/null 2>&1; then
        echo "✓ release $TAG exists"
        exit 0
    fi
    if [ "$waited" -ge "$WAIT" ]; then
        echo "✗ release $TAG still missing after ${WAIT}s — check the Auto Tag & Release run in the Actions tab;" >&2
        echo "  the notarized DMGs are kept, so once the draft exists run: make publish-upload" >&2
        exit 1
    fi
    if [ "$announced" -eq 0 ]; then
        echo "==> waiting for the CI to draft release $TAG (it validates the tag first)"
        announced=1
    fi
    sleep "$POLL"
    waited=$((waited + POLL))
done
