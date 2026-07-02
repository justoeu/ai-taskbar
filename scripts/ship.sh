#!/usr/bin/env bash
# ship.sh — one-shot release: sync → wait for CI auto-tag → pull → publish.
#
# Chains the whole release ritual so the maintainer never has to remember the
# order. Steps:
#   1. Guards: on main, clean tree, signing env present, gh authenticated.
#   2. Sync with origin/main: pull --rebase when the remote is ahead (e.g.
#      the CI bump commit already landed for an earlier push), push when we
#      have local commits. A blind push here bit us on the first run — the
#      remote already carried the CI's chore(release) commit and rejected it.
#   3. Poll until HEAD carries a vX.Y.Z tag (the CI bump). While polling,
#      inspect the newest "Auto Tag & Release" run: a conclusion of
#      "skipped" ([skip release] / chore(release) head) means no release was
#      cut — abort gracefully; a failure aborts loudly.
#   4. make publish (builds, signs, notarizes and uploads both DMGs, then
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

# ── 2. sync with origin/main ─────────────────────────────────────────────────
# Pull first when the remote is ahead (the CI bump for an earlier push may
# already be there), then push only if we still carry local commits.
sync_main() {
    git fetch --quiet origin main
    git fetch --tags --quiet
    if ! git merge-base --is-ancestor origin/main HEAD; then
        git pull --rebase --quiet origin main
    fi
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
        info "pushing main ($(git rev-parse HEAD))"
        git push --quiet origin main
    fi
}
info "syncing with origin/main"
sync_main

# ── 3. wait until HEAD carries the CI's release tag ──────────────────────────
current_tag() {
    git tag --points-at HEAD | grep -E '^v[0-9]' | head -n1 || true
}
info "waiting for the CI bump + tag (Auto Tag & Release)"
TAG=$(current_tag)
for _ in $(seq 1 60); do   # up to ~10 min
    [ -n "$TAG" ] && break
    # Abort early when the newest run on main already concluded badly.
    RUN_JSON=$(gh run list --workflow "Auto Tag & Release" --branch main \
               --limit 1 --json status,conclusion \
               --jq '.[0] | "\(.status) \(.conclusion)"' || echo "")
    STATUS=${RUN_JSON%% *}
    CONCLUSION=${RUN_JSON#* }
    if [ "$STATUS" = "completed" ]; then
        case "$CONCLUSION" in
            skipped) info "run skipped — head commit opted out ([skip release] / chore(release)); nothing to publish"; exit 0 ;;
            success) : ;;   # bump may still be propagating; keep polling
            *)       red "Auto Tag & Release concluded: $CONCLUSION — fix CI before publishing"; exit 1 ;;
        esac
    fi
    sleep 10
    sync_main
    TAG=$(current_tag)
done
if [ -z "$TAG" ]; then
    red "timed out waiting for the release tag on HEAD — check the Actions tab"; exit 1
fi
ok "HEAD is $TAG"

# ── 5. publish ───────────────────────────────────────────────────────────────
info "building, notarizing and publishing $TAG"
make publish
