#!/usr/bin/env bash
# build_icon.sh — render the AppIcon PNGs at every required size and assemble
# them into Resources/AppIcon.icns via Apple's iconutil.
#
# Idempotent: re-running just overwrites the existing .icns. Safe to call
# from `make app` / CI.

set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="build/AppIcon.iconset"
OUT_ICNS="Resources/AppIcon.icns"

mkdir -p build
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "==> Rendering PNGs…"
swift scripts/generate_icon.swift "$ICONSET"

echo "==> Building $OUT_ICNS via iconutil…"
iconutil --convert icns "$ICONSET" --output "$OUT_ICNS"
rm -rf "$ICONSET"

echo "✓ $OUT_ICNS"
file "$OUT_ICNS"
