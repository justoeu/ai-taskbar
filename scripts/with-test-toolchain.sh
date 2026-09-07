#!/usr/bin/env bash
# Run test tooling with a complete Xcode toolchain. CLT 6.3.2's SwiftPM
# cannot locate its bundled Testing framework/runtime reliably. Never change
# xcode-select globally or mix framework paths from different installations.
set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "Usage: with-test-toolchain.sh command [args...]" >&2
    exit 64
fi

platform_available() {
    /usr/bin/xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1
}

if [ "${DEVELOPER_DIR+x}" = x ]; then
    # An explicit selection is authoritative, including an invalid one.
    if [ -z "$DEVELOPER_DIR" ] || ! platform_available; then
        echo "Tests require a full Xcode toolchain; set DEVELOPER_DIR to its Contents/Developer directory." >&2
        exit 1
    fi
elif ! platform_available; then
    fallback=/Applications/Xcode.app/Contents/Developer
    if [ ! -x "$fallback/usr/bin/xcodebuild" ]; then
        echo "Tests require full Xcode. Install it and set DEVELOPER_DIR to its Contents/Developer directory." >&2
        exit 1
    fi
    export DEVELOPER_DIR="$fallback"
    if ! platform_available; then
        echo "The installed Xcode toolchain is unavailable; check Xcode setup or set DEVELOPER_DIR explicitly." >&2
        exit 1
    fi
    echo "Using Xcode for tests: $DEVELOPER_DIR" >&2
fi

exec "$@"
