#!/usr/bin/env bash
# Source-level ratchets shared by scripts/validate.sh and .github/workflows/ci.yml.
# One definition so the two cannot drift (they did: the vacuous-#expect regex
# was copy-pasted into ci.yml and neither copy had a positive control).
#
#   scripts/check-source-ratchets.sh
#
# Knobs, used by scripts/source-ratchet-selftest.sh to aim the checks at a
# planted scratch tree instead of the repo:
#   TESTS_DIR       (default: Tests)
#   WIRE_TYPES_DIR  (default: Sources/AiTaskbarProviders)
#
# Exits non-zero, printing up to 5 offending locations, when either check
# fires. If you change a pattern here, run scripts/source-ratchet-selftest.sh:
# it plants every form each check must reject and every form it must accept.

set -euo pipefail
cd "$(dirname "$0")/.."

tests_dir="${TESTS_DIR:-Tests}"
wire_dir="${WIRE_TYPES_DIR:-Sources/AiTaskbarProviders}"
status=0

# 1. Vacuous #expect / #require forms.
#
# The former mixed Swift 6.3.2 / standalone Testing 0.99.0 stack mis-evaluated
# Bool sub-expressions. These forms all PASSED when false — verified by
# running them, not by reading the macro:
#
#   #expect(false == true)                    #expect(opt ?? false)
#   #expect(opt == Optional(false))           #expect(opt.map { !$0 } ?? false)
#
# and `#expect(!(opt ?? true))` is inverted outright. Use expectTrue /
# expectFalse (Sources/AiTaskbarTestSupport/ExpectBool.swift), which take a
# plain Bool parameter so the condition is evaluated as ordinary Swift before
# the macro sees it. Bare `#expect(flag)` / `#expect(!flag)` on a non-optional
# Bool is fine, as are non-Bool comparisons (`#expect(n == 3)`).
#
# The first version of this check was a single-line grep that required `)`
# right after the literal, so `#expect(opt == false, "msg")`, `!= true`,
# `#require(...)` and any assert split across lines all slipped through. This
# one extracts each macro's whole balanced argument list (multi-line) and
# inspects that, after blanking string literals (a message may legitimately
# say "== true", and a literal like "and (" must not unbalance the parens) and
# comments. Closure bodies inside the arguments (`xs.first { $0.a == true }`)
# are ordinary Swift the macro never decomposes, so they are exempt. A call
# whose parentheses still cannot be balanced is reported rather than skipped:
# fail closed.
# No `|| true` on these pipelines, on purpose: perl exits 0 whether or not it
# finds anything, so a non-zero status means the check itself broke (missing
# directory, perl error) and must fail the gate rather than read as "clean".
if ! vacuous=$(find "$tests_dir" -name '*.swift' -type f -print0 | sort -z \
    | xargs -0 perl -0777 -ne '
        my $src = $_;
        # Blank string literals and comments but keep every newline, so line
        # numbers stay exact.
        $src =~ s{""".*?"""}{ (my $m = $&) =~ s/[^\n]//g; q("") . $m }gse;
        $src =~ s{"(?:[^"\\\n]|\\.)*"}{""}g;
        $src =~ s{/\*.*?\*/}{ (my $m = $&) =~ s/[^\n]//g; $m }gse;
        $src =~ s{^([ \t]*)//[^\n]*}{$1}mg;
        while ($src =~ /#(expect|require)\s*(?=\()/g) {
            my ($macro, $at) = ($1, pos($src));
            my $line = 1 + (substr($src, 0, $at) =~ tr/\n//);
            my $rest = substr($src, $at);
            if ($rest !~ /^(\((?:[^()]++|(?1))*+\))/s) {
                print "$ARGV:$line: #$macro( with unbalanced parentheses — cannot verify\n";
                next;
            }
            (my $args = $1) =~ s/\s+/ /g;
            $args =~ s/(\{(?:[^{}]++|(?1))*+\})/{}/g;
            if ($args =~ /[!=]=\s*(?:true|false)\b/
                || $args =~ /\b(?:true|false)\s*[!=]=/
                || $args =~ /\?\?\s*(?:true|false)\b/
                || $args =~ /[!=]=\s*(?:Optional\s*(?:<[^>]*>)?\s*\(|\.some\s*\()/) {
                print "$ARGV:$line: #$macro$args\n";
            }
        }
    '); then
    echo "  ✗ vacuous-#expect check could not run (tests dir: $tests_dir)"
    exit 1
fi
if [ -n "$vacuous" ]; then
    echo "$vacuous" | head -5
    n=$(printf '%s\n' "$vacuous" | wc -l | tr -d ' ')
    echo "  ✗ $n vacuous #expect/#require form(s) — use expectTrue/expectFalse (AiTaskbarTestSupport)"
    status=1
else
    echo "  ✓ no vacuous #expect/#require forms"
fi

# 2. Trapping Double->Int ratchet (B3-numeric). `Int(_: Double)` is a fatal
# error for NaN, infinity or out-of-range values, and wire types decode
# untrusted vendor JSON where `1e300` is valid. In *WireTypes.swift every
# integer conversion must use a labeled, non-trapping initializer
# (`saturating:` / `checkedTruncating:` from Core's SafeNumeric.swift, or
# `exactly:` / `clamping:` / `truncatingIfNeeded:`). Comment lines and
# `radix:` string parses are exempt. The point-free `Int.init` (as in
# `.map(Int.init)`) is the unlabeled initializer too, so it is rejected
# unless it names one of those labels.
if ! bare_int=$(find "$wire_dir" -maxdepth 1 -name '*WireTypes.swift' -type f -print0 | sort -z \
    | xargs -0 perl -ne '
        next if /^\s*\/\//;
        next if /radix:/;
        my $hit = /\bU?Int(?:8|16|32|64)?\((?:\s*[^a-zA-Z_ )]|\s*[a-zA-Z_][a-zA-Z0-9_.]*[^a-zA-Z0-9_.:])/
            || /\bU?Int(?:8|16|32|64)?\.init\b(?!\s*\(\s*(?:saturating|checkedTruncating|exactly|clamping|truncatingIfNeeded)\s*:)/;
        print "$ARGV:$.: $_" if $hit;
    } continue { close ARGV if eof;
    '); then
    echo "  ✗ wire-types integer check could not run (dir: $wire_dir)"
    exit 1
fi
if [ -n "$bare_int" ]; then
    echo "$bare_int" | head -5
    echo "  ✗ bare Int(...) conversion in *WireTypes.swift — use Int(saturating:) / Int(checkedTruncating:)"
    status=1
else
    echo "  ✓ no trapping integer conversions in wire types"
fi

exit "$status"
