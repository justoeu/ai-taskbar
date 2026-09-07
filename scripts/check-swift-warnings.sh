#!/usr/bin/env bash
# Shared by local validation, CI, and the planted-warning self-test.
# Inspect every diagnostic header, including Tests/, macro expansions and ld.
set -euo pipefail

log=${1:?Usage: check-swift-warnings.sh build.log [--count]}
test -f "$log"
warnings=$(awk '/^(warning:|[^[:space:]|].*: warning:)/ { print }' "$log" | sort -u)
# Only deprecations of the unavoidable classic Keychain API are tolerated,
# both in its implementation and in the isolated-keychain test fixtures.
legacy='(Sources/AiTaskbarCore/Credentials/(KeychainAccessAuthorizer|KeychainCredentialReader|KeychainPromptSuppressor)|Tests/AiTaskbarCoreTests/(KeychainAccessAuthorizerTests|KeychainCredentialReaderTests|TemporaryKeychain))\.swift:[0-9]+:[0-9]+: warning:.*was deprecated'
unexpected=$(printf '%s\n' "$warnings" | grep -vE "$legacy|^$" || true)
count=$(printf '%s\n' "$unexpected" | grep -c . || true)
if [ "${2:-}" = --count ]; then
    printf '%s\n' "$count"
    exit 0
fi
if [ "$count" -gt 0 ]; then
    printf '%s\n' "$unexpected" >&2
    echo "$count warning(s) outside the legacy-Keychain deprecation allowlist" >&2
    exit 1
fi
echo "No warnings outside the legacy-Keychain deprecation allowlist"
