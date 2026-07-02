#!/usr/bin/env bash
# ship.sh — one-shot release: push → wait for CI auto-tag → pull → publish.
#
# Chains the whole release ritual so the maintainer never has to remember the
# order. Steps:
#   1. Guards: on main, clean tree, signing env present, gh authenticated.
#   2. git push origin main (no-op if already pushed).
#   3. Wait for the "Auto Tag & Release" run for THIS head SHA to finish.
#      A conclusion of "skipped" ([skip release] / chore(release) head) means
#      no release was cut — abort gracefully.
#   4. git pull --rebase + fetch tags (brings the CI bump commit + vX.Y.Z).
#   5. make publish (builds, signs, notarizes and uploads both DMGs, then
#      flips the draft release to published).
#
# Required env (same as make publish):
#   DEVELOPER_ID                          Developer ID Application identity
#   NOTARY_PROFILE  or  APPLE_ID + APPLE_TEAM_ID + APPLE_PASSWORD
set -euo pipefail

red()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# ── 1. guards ────────────────────────────────────────────────────────────────
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    red "ship runs from main (current: $BRANCH)"; exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    red "working tree not clean — commit or stash first"; exit 1
fi
if [ -z "${DEVELOPER_ID:-}" ]; then
    red 'DEVELOPER_ID not set. Example: DEVELOPER_ID="Developer ID Application: Your Name (TEAM12345)"'; exit 1
fi
if [ -z "${NOTARY_PROFILE:-}" ] && { [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${APPLE_PASSWORD:-}" ]; }; then
    red "notarization credentials missing — set NOTARY_PROFILE (xcrun notarytool store-credentials) or APPLE_ID/APPLE_TEAM_ID/APPLE_PASSWORD"; exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    red "gh CLI not authenticated — run: gh auth login"; exit 1
fi

HEAD_SHA=$(git rev-parse HEAD)

# ── 2. push ──────────────────────────────────────────────────────────────────
info "pushing main ($HEAD_SHA)"
git push origin main

# ── 3. wait for the auto-tag run on this SHA ─────────────────────────────────
info "waiting for 'Auto Tag & Release' run for $HEAD_SHA"
RUN_ID=""
for _ in $(seq 1 24); do   # up to ~2 min for the run to appear
    RUN_ID=$(gh run list --workflow "Auto Tag & Release" --branch main \
             --json databaseId,headSha --limit 10 \
             --jq "first(.[] | select(.headSha == \"$HEAD_SHA\")) | .databaseId" || true)
    [ -n "$RUN_ID" ] && break
    sleep 5
done
if [ -z "$RUN_ID" ]; then
    red "no workflow run appeared for $HEAD_SHA — check the Actions tab"; exit 1
fi

# watch may exit non-zero for skipped runs; the conclusion check below decides.
gh run watch "$RUN_ID" --exit-status >/dev/null 2>&1 || true
CONCLUSION=$(gh run view "$RUN_ID" --json conclusion --jq .conclusion)
case "$CONCLUSION" in
    success) ok "CI tagged and drafted the release" ;;
    skipped) info "run skipped — head commit opted out ([skip release] / chore(release)); nothing to publish"; exit 0 ;;
    *)       red "workflow run $RUN_ID ended with: $CONCLUSION — fix CI before publishing"; exit 1 ;;
esac

# ── 4. pull the bump commit + tag ────────────────────────────────────────────
info "pulling bump commit + tags"
git pull --rebase origin main
git fetch --tags --quiet

TAG=$(git tag --points-at HEAD | grep -E '^v[0-9]' | head -n1 || true)
if [ -z "$TAG" ]; then
    red "HEAD is not tagged after pull — did the tag job cut a version?"; exit 1
fi
ok "HEAD is $TAG"

# ── 5. publish ───────────────────────────────────────────────────────────────
info "building, notarizing and publishing $TAG"
make publish
