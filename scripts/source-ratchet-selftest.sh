#!/usr/bin/env bash
# Positive AND negative control for scripts/check-source-ratchets.sh.
#
# A gate that cannot fail is worse than no gate (see warn-ratchet-selftest.sh
# for the time that happened). The vacuous-#expect grep shipped with a hole:
# it required `)` right after the literal, so `#expect(opt == false, "msg")`
# sailed through and a live instance sat in PinStoreTests. This script plants
# every form each check must reject — one per scratch tree, so each is proven
# individually — and every form it must accept, and fails if the gate gets
# either side wrong.
#
#   ./scripts/source-ratchet-selftest.sh
#
# Pure grep/perl, no build: runs in well under a second, so validate.sh and CI
# run it on every pass instead of trusting that someone remembers to.

set -euo pipefail
cd "$(dirname "$0")/.."

CHECK="scripts/check-source-ratchets.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/empty"
failures=0
n=0

# expect_reject <kind> <label> <file-name> <content>
#   kind = tests | wire. Plants <content> alone and requires the matching
#   check to fire (exit non-zero AND the check's own ✗ line naming the file),
#   so a crash of the check is not mistaken for a detection.
expect_reject() {
    local kind=$1 label=$2 name=$3 content=$4 dir out rc=0 marker
    n=$((n + 1))
    dir="$work/reject-$n"
    mkdir -p "$dir"
    printf '%s\n' "$content" > "$dir/$name"
    if [ "$kind" = tests ]; then
        marker="vacuous #expect/#require form"
        out=$(TESTS_DIR="$dir" WIRE_TYPES_DIR="$work/empty" "$CHECK" 2>&1) || rc=$?
    else
        marker="bare Int(...) conversion"
        out=$(TESTS_DIR="$work/empty" WIRE_TYPES_DIR="$dir" "$CHECK" 2>&1) || rc=$?
    fi
    if [ "$rc" -ne 0 ] && grep -qF "$marker" <<<"$out" && grep -qF "$dir/$name" <<<"$out"; then
        echo "  ✓ rejects: $label"
    else
        echo "  ✗ GATE IS BLIND to: $label (exit $rc)"
        sed 's/^/      /' <<<"$out"
        failures=$((failures + 1))
    fi
}

echo "[1/4] vacuous #expect / #require forms — each must fail the gate"
expect_reject tests '== false + message'        T.swift '#expect(opt == false, "msg")'
expect_reject tests '== true + message w/ interp' T.swift '#expect(pin?.isEmpty == true, "pin for \(host)")'
expect_reject tests '!= true'                   T.swift '#expect(opt != true)'
expect_reject tests '!= false + message'        T.swift '#expect(opt != false, "m")'
expect_reject tests 'false == true'             T.swift '#expect(false == true)'
expect_reject tests 'literal on the left'       T.swift '#expect(true == opt)'
expect_reject tests '?? false'                  T.swift '#expect(opt ?? false)'
expect_reject tests '.map { !$0 } ?? false'     T.swift '#expect(opt.map { !$0 } ?? false)'
expect_reject tests '!(opt ?? true)'            T.swift '#expect(!(opt ?? true))'
expect_reject tests '== Optional(false)'        T.swift '#expect(opt == Optional(false))'
expect_reject tests '== .some(true)'            T.swift '#expect(opt == .some(true))'
expect_reject tests '#require(opt == true)'     T.swift 'let v = try #require(opt == true)'
expect_reject tests 'multi-line assert'         T.swift $'#expect(\n    opt ==\n        false\n)'
expect_reject tests 'multi-line + message'      T.swift $'#expect(opt?.isEmpty\n    == false,\n    "x")'
expect_reject tests 'unbalanced call (fail closed)' T.swift '#expect(foo(bar'

echo "[2/4] allowed assert forms — the gate must pass"
mkdir -p "$work/accept-tests"
cat > "$work/accept-tests/Ok.swift" <<'SWIFT'
// #expect(opt == false) in a line comment is prose, not an assert.
/* #expect(opt ?? false) in a block comment too. */
func ok() throws {
    expectTrue(opt == true)
    expectFalse(opt ?? true, "empty pin for \(host)")
    expectFalse(pin?.isEmpty ?? true)
    #expect(flag)
    #expect(!flag)
    #expect(n == 3)
    #expect(pin.count == 44, "pin for \(host)")
    #expect(s == "b", "message may say == true")
    #expect(x != errSecSuccess, "anchor apple and (")
    let r = try #require(xs.first { $0.url?.path.hasSuffix("/a") == true })
    let m = try #require(
        URLComponents(url: u, resolvingAgainstBaseURL: false)
    )
    #expect(s == """
    == true (
    """)
}
SWIFT
mkdir -p "$work/accept-wire"
cat > "$work/accept-wire/OkWireTypes.swift" <<'SWIFT'
// Int($0) in a comment is exempt.
let a = Int(saturating: d)
let b = Int(checkedTruncating: d)
let c = Int(exactly: d)
let e = Int(clamping: n)
let f = UInt8(truncatingIfNeeded: n)
let g = Int(s, radix: 16)
let h = xs.map(Int.init(saturating:))
let i = Int.init(checkedTruncating: d)
let j = Int64(saturating: d)
SWIFT
rc=0
out=$(TESTS_DIR="$work/accept-tests" WIRE_TYPES_DIR="$work/accept-wire" "$CHECK" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "  ✓ accepts expectTrue/expectFalse, non-optional #expect, closures, messages, comments, labeled Int inits"
else
    echo "  ✗ gate rejects an allowed form (exit $rc):"
    sed 's/^/      /' <<<"$out"
    failures=$((failures + 1))
fi

echo "[3/4] trapping integer conversions in *WireTypes.swift — each must fail the gate"
expect_reject wire 'Int($0)'               FooWireTypes.swift 'let a = xs.map { Int($0) }'
expect_reject wire 'Int(x.rounded())'      FooWireTypes.swift 'let a = Int(x.rounded())'
expect_reject wire 'Int(value)'            FooWireTypes.swift 'let a = Int(value)'
expect_reject wire 'Int64(d)'              FooWireTypes.swift 'let a = Int64(d)'
expect_reject wire 'UInt8(x * 2)'          FooWireTypes.swift 'let a = UInt8(x * 2)'
expect_reject wire 'point-free .map(Int.init)' FooWireTypes.swift 'let a = xs.map(Int.init)'
expect_reject wire 'Int.init(d)'           FooWireTypes.swift 'let a = Int.init(d)'

echo "[4/4] a missing directory must fail closed, not read as clean"
rc=0
TESTS_DIR="$work/does-not-exist" WIRE_TYPES_DIR="$work/empty" "$CHECK" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    echo "  ✓ missing tests dir fails the gate"
else
    echo "  ✗ missing tests dir reported clean"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    echo "  ✗ source-ratchet self-test: $failures case(s) wrong"
    exit 1
fi
echo "  ✓ source-ratchet self-test passed"
