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

# plant_strings <dir> <en> <pt-BR> <es> — one Localizable.strings per language.
plant_strings() {
    local dir=$1
    mkdir -p "$dir/en.lproj" "$dir/pt-BR.lproj" "$dir/es.lproj"
    printf '%s\n' "$2" > "$dir/en.lproj/Localizable.strings"
    printf '%s\n' "$3" > "$dir/pt-BR.lproj/Localizable.strings"
    printf '%s\n' "$4" > "$dir/es.lproj/Localizable.strings"
}
# A clean strings tree, so the tests/wire cases never depend on the repo's.
plant_strings "$work/strings-ok" '"k" = "v";' '"k" = "v";' '"k" = "v";'
export STRINGS_DIR="$work/strings-ok"
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

echo "[1/6] vacuous #expect / #require forms — each must fail the gate"
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

echo "[2/6] allowed assert forms — the gate must pass"
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
let k = Int(String(x), radix: 16)
let m = UInt8(s, radix: 2) ?? 0
let p = Int(String(Int(saturating: d)), radix: 16)
let q = Int(Int(s, radix: 16).map(String.init) ?? "", radix: 10)
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

echo "[3/6] trapping integer conversions in *WireTypes.swift — each must fail the gate"
expect_reject wire 'Int($0)'               FooWireTypes.swift 'let a = xs.map { Int($0) }'
expect_reject wire 'Int(x.rounded())'      FooWireTypes.swift 'let a = Int(x.rounded())'
expect_reject wire 'Int(value)'            FooWireTypes.swift 'let a = Int(value)'
expect_reject wire 'Int64(d)'              FooWireTypes.swift 'let a = Int64(d)'
expect_reject wire 'UInt8(x * 2)'          FooWireTypes.swift 'let a = UInt8(x * 2)'
expect_reject wire 'point-free .map(Int.init)' FooWireTypes.swift 'let a = xs.map(Int.init)'
expect_reject wire 'Int.init(d)'           FooWireTypes.swift 'let a = Int.init(d)'
expect_reject wire 'radix parse + Int(d) on one line' FooWireTypes.swift 'let a = Int(s, radix: 16) ?? Int(d)'
expect_reject wire 'Int(d) nested in a radix call' FooWireTypes.swift 'let a = Int(String(Int(d)), radix: 16)'
expect_reject wire 'Int(Int(d), radix: 16)'        FooWireTypes.swift 'let a = Int(Int(d), radix: 16)'
expect_reject wire 'Int(d) as the radix argument'  FooWireTypes.swift 'let a = Int(s, radix: Int(d))'

# expect_reject_strings <label> <en> <pt-BR> <es> — requires the strings
# check's own ✗ line, so a crash is not mistaken for a detection.
expect_reject_strings() {
    local label=$1 dir out rc=0
    n=$((n + 1))
    dir="$work/reject-$n"
    plant_strings "$dir" "$2" "$3" "$4"
    out=$(TESTS_DIR="$work/empty" WIRE_TYPES_DIR="$work/empty" STRINGS_DIR="$dir" "$CHECK" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "Localizable.strings integer specifier / parity violation" <<<"$out"; then
        echo "  ✓ rejects: $label"
    else
        echo "  ✗ GATE IS BLIND to: $label (exit $rc)"
        sed 's/^/      /' <<<"$out"
        failures=$((failures + 1))
    fi
}

echo "[4/6] 32-bit integer specifiers and language drift in Localizable.strings — each must fail the gate"
expect_reject_strings '%d'                      '"a_fmt" = "%d%%";'  '"a_fmt" = "%d%%";'  '"a_fmt" = "%d%%";'
expect_reject_strings '%i'                      '"a_fmt" = "%i x";'  '"a_fmt" = "%i x";'  '"a_fmt" = "%i x";'
expect_reject_strings 'positional %1$d'         '"a_fmt" = "%1$d";'  '"a_fmt" = "%1$d";'  '"a_fmt" = "%1$d";'
expect_reject_strings '%hd'                     '"a_fmt" = "%hd";'   '"a_fmt" = "%hd";'   '"a_fmt" = "%hd";'
expect_reject_strings '%d in one language only' '"a_fmt" = "%ld";'   '"a_fmt" = "%d";'    '"a_fmt" = "%ld";'
expect_reject_strings 'key missing in es' \
    $'"a" = "x";\n"b" = "y";' $'"a" = "x";\n"b" = "y";' '"a" = "x";'
expect_reject_strings 'specifier mismatch'      '"a_fmt" = "%ld";'   '"a_fmt" = "%@";'    '"a_fmt" = "%ld";'
expect_reject_strings 'missing argument'        '"a_fmt" = "%ld-%ld";' '"a_fmt" = "%ld";' '"a_fmt" = "%ld-%ld";'
expect_reject_strings 'unparseable entry (fail closed)' '"a_fmt" = "%ld"' '"a_fmt" = "%ld";' '"a_fmt" = "%ld";'

echo "[5/6] allowed strings forms — the gate must pass"
plant_strings "$work/accept-strings" \
    $'/* block comment with %d */\n// line comment %d\n"a_fmt" = "%@ at %ld%%";\n"b_fmt" = "%1$@ has %2$ld";\n"c_fmt" = "%lld %qd %zd";\n"d" = "above 90% now (% Quota)";\n"e_fmt" = "%.1f \\"q\\"";' \
    $'"a_fmt" = "%@ em %ld%%";\n"b_fmt" = "%2$ld em %1$@";\n"c_fmt" = "%lld %qd %zd";\n"d" = "acima de 90% agora (% Quota)";\n"e_fmt" = "%.1f";' \
    $'"a_fmt" = "%@ al %ld%%";\n"b_fmt" = "%1$@ tiene %2$ld";\n"c_fmt" = "%lld %qd %zd";\n"d" = "90% ahora (% Cuota)";\n"e_fmt" = "%.1f";'
rc=0
out=$(TESTS_DIR="$work/empty" WIRE_TYPES_DIR="$work/empty" STRINGS_DIR="$work/accept-strings" "$CHECK" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "  ✓ accepts %ld, reordered positional %2\$ld, %lld/%qd/%zd, %%, prose percent, escaped quotes, comments"
else
    echo "  ✗ gate rejects an allowed strings form (exit $rc):"
    sed 's/^/      /' <<<"$out"
    failures=$((failures + 1))
fi

echo "[6/6] a missing directory or strings file must fail closed, not read as clean"
rc=0
mkdir -p "$work/strings-partial/en.lproj"
cp "$work/strings-ok/en.lproj/Localizable.strings" "$work/strings-partial/en.lproj/"
TESTS_DIR="$work/empty" WIRE_TYPES_DIR="$work/empty" STRINGS_DIR="$work/strings-partial" "$CHECK" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    echo "  ✓ missing pt-BR/es strings fails the gate"
else
    echo "  ✗ missing strings files reported clean"
    failures=$((failures + 1))
fi
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
