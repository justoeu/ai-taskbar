#!/usr/bin/env bash
# Prints the supported vendors' display names, comma-separated, straight from
# `VendorId.displayName` — so release notes never carry a hand-kept list that
# goes stale (v0.24.0's still named five of nine). Fails if the switch cannot
# be read or does not cover every `VendorId` case.
set -euo pipefail
file="${1:-Sources/AiTaskbarCore/Models/VendorId.swift}"
names=$(awk '/var displayName: String/{f=1; next} f && /^[[:space:]]*}/{exit} f' "$file" \
    | sed -nE 's/^[[:space:]]*case \.[a-z]+:[[:space:]]*return "([^"]+)".*/\1/p')
cases=$(awk '/^public enum VendorId/{f=1; next} f && /^}/{exit} f' "$file" \
    | grep -cE '^[[:space:]]*case [a-z]+[[:space:]]*$' || true)
count=$(printf '%s\n' "$names" | grep -c . || true)
if [ "$count" -eq 0 ] || [ "$count" -ne "$cases" ]; then
    echo "vendor-list: read $count display names for $cases VendorId cases in $file" >&2
    exit 1
fi
printf '%s\n' "$names" | paste -sd ',' - | sed 's/,/, /g'
