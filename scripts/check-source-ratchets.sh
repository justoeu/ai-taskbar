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
#   STRINGS_DIR     (default: Sources/AiTaskbarApp/Resources; holds
#                    {en,pt-BR,es}.lproj/Localizable.strings)
#   SWIFT_FORMAT_DIR (default: Sources; every *.swift below it is scanned for
#                    inline String(format: "...") literals)
#
# Exits non-zero, printing up to 5 offending locations, when any of the four
# checks fires. If you change a pattern here, run scripts/source-ratchet-selftest.sh:
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
        # Neutralise only the radix string parses themselves (balanced
        # parentheses, so Int(String(x), radix: 16) is one call); skipping the
        # whole line let `Int(s, radix: 16) ?? Int(d)` through (TEST-MAE-007).
        # Only the `Int` name is renamed: the arguments are scrubbed
        # recursively and kept, so a trapping conversion nested inside, as in
        # `Int(String(Int(d)), radix: 16)`, is still seen (TEST-MAE-010).
        # `radix:` must be a TOP-LEVEL argument of the call itself.
        sub scrub {
            my ($s) = @_;
            $s =~ s{\b(U?Int(?:8|16|32|64)?)(\((?:[^()]++|(?2))*\))}{
                my ($name, $call) = ($1, $2);
                my $inner = scrub(substr($call, 1, -1));
                (my $top = $inner) =~ s/(\((?:[^()]++|(?1))*\))/()/g;
                ($top =~ /\bradix\s*:/ ? "RADIX_PARSE" : $name) . "(" . $inner . ")"
            }ge;
            return $s;
        }
        my $l = scrub($_);
        my $hit = $l =~ /\bU?Int(?:8|16|32|64)?\((?:\s*[^a-zA-Z_ )]|\s*[a-zA-Z_][a-zA-Z0-9_.]*[^a-zA-Z0-9_.:])/
            || $l =~ /\bU?Int(?:8|16|32|64)?\.init\b(?!\s*\(\s*(?:saturating|checkedTruncating|exactly|clamping|truncatingIfNeeded)\s*:)/;
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

# 3. Localizable.strings integer specifiers + language parity (BUG-MAE-015).
# Every integer a call site formats is a Swift `Int`, which is 64-bit; `%d` /
# `%i` read 32 bits of it, so `notif_discreet_body_fmt` fed an unclamped
# 5_000_000_000 threshold printed 705032704. Integer conversions must carry a
# 64-bit length modifier (`%ld`, `%1$ld`, `%lld`, `%qd`, `%zd`, `%jd`, `%td`);
# a bare or `h`/`hh` `%d`/`%i`/`%u`/`%o`/`%x`/`%X` fails (TEST-MAE-012: the
# unsigned conversions read 32 bits of the vararg just the same). If an argument is ever genuinely Int32,
# widen it to Int at the call site rather than special-casing the gate.
# A key may be defined only once per file (BUG-MAE-016: "done" was defined
# twice with two different pt-BR words, and which one showed depended on the
# parser keeping the last duplicate).
# The three languages must also carry identical key sets and, per key, the
# identical specifier list (ordered by argument index, so a translation may
# reorder positional `%1$@ … %2$ld` forms), since a missing or mismatched
# specifier in one language reads the wrong vararg at runtime.
# The space flag is deliberately not parsed: prose keys looked up without args
# ("90% ahora", "(% Quota)") would otherwise read as `% a` / `% Q` specifiers,
# and no format key here uses that flag.
strings_dir="${STRINGS_DIR:-Sources/AiTaskbarApp/Resources}"
strings_files=()
for lang in en pt-BR es; do
    strings_files+=("$strings_dir/$lang.lproj/Localizable.strings")
done
for f in "${strings_files[@]}"; do
    if [ ! -f "$f" ]; then
        echo "  ✗ strings check could not run (missing $f)"
        exit 1
    fi
done
if ! bad_fmt=$(perl -0777 -ne '
        my $src = $_;
        $src =~ s{/\*.*?\*/}{ (my $m = $&) =~ s/[^\n]//g; $m }gse;
        my $line = 0;
        for my $l (split /\n/, $src, -1) {
            $line++;
            $l =~ s{^\s*//.*}{};
            next if $l =~ /^\s*$/;
            if ($l !~ /^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*(?:\/\/.*)?$/) {
                print "$ARGV:$line: unparseable entry — cannot verify\n";
                next;
            }
            my ($key, $val) = ($1, $2);
            my ($next, @specs) = (1);
            while ($val =~ /%(?:(\d+)\$)?[-+#0\x27]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|z|t|j|L)?([diouxXeEfFgGaAcCsSp@%])/g) {
                my ($pos, $len, $conv) = ($1, $2 // "", $3);
                next if $conv eq "%";
                if ($conv =~ /^[diouxX]$/ && $len !~ /^(?:l|ll|q|z|t|j)$/) {
                    print "$ARGV:$line: \"$key\" uses %$len$conv — use %l$conv for a Swift Int\n";
                }
                my $idx = defined $pos ? $pos : $next++;
                push @specs, [$idx, "$len$conv"];
            }
            my $sig = join ",", map { "$_->[0]:$_->[1]" } sort { $a->[0] <=> $b->[0] } @specs;
            print "$ARGV:$line: duplicate key \"$key\" (first defined on line $first{$ARGV}{$key})\n"
                if exists $first{$ARGV}{$key};
            $first{$ARGV}{$key} //= $line;
            $seen{$ARGV}{$key} = $sig;
        }
        END {
            my @files = sort keys %seen;
            my %all;
            for my $f (@files) { $all{$_} = 1 for keys %{$seen{$f}} }
            for my $k (sort keys %all) {
                my %sigs;
                for my $f (@files) {
                    if (!exists $seen{$f}{$k}) { print "$f: missing key \"$k\"\n"; next }
                    $sigs{$seen{$f}{$k}} = 1;
                }
                print "\"$k\": specifiers differ across languages (", join(" | ", sort keys %sigs), ")\n"
                    if keys %sigs > 1;
            }
        }
    ' "${strings_files[@]}"); then
    echo "  ✗ strings check could not run (dir: $strings_dir)"
    exit 1
fi
if [ -n "$bad_fmt" ]; then
    echo "$bad_fmt" | head -5
    echo "  ✗ Localizable.strings integer specifier / duplicate key / parity violation — use %ld, define each key once, keep en, pt-BR, es in lockstep"
    status=1
else
    echo "  ✓ Localizable.strings: 64-bit integer specifiers, unique keys, identical keys and specifiers in en/pt-BR/es"
fi

# 4. Inline String(format: "...") literals in Swift sources (BUG-MAE-017).
# Same 32-bit read as check 3, one layer down: `String(format: " (%d%%)",
# pct)` and xAI's `"%04d-%02d"` cycle label fed a Swift `Int` to `%d`, so a
# year above Int32.max printed its low word. Signed conversions (`%d`, `%i`)
# in a literal must carry a 64-bit length modifier (`%ld`, `%02ld`, `%04ld`).
# Unsigned conversions (`%x`, `%X`, `%o`, `%u`) are not checked here: in Swift
# source they format explicitly fixed-width UInt8/UInt32 values (hex digests,
# `\\u%04X` scalars, the quarantine timestamp), where 32 bits is the correct
# width. Only the literal argument is inspected; formats looked up through
# L10n are covered by check 3. Line comments are ignored.
swift_dir="${SWIFT_FORMAT_DIR:-Sources}"
if ! bad_inline=$(find "$swift_dir" -name '*.swift' -type f -print0 | sort -z \
    | xargs -0 perl -0777 -ne '
        my $src = $_;
        $src =~ s{^([ \t]*)//[^\n]*}{$1}mg;
        while ($src =~ /\bString\s*\(\s*format\s*:\s*"((?:[^"\\\n]|\\.)*)"/g) {
            my ($fmt, $at) = ($1, $-[0]);
            my $line = 1 + (substr($src, 0, $at) =~ tr/\n//);
            while ($fmt =~ /%(?:\d+\$)?[-+#0\x27]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|z|t|j|L)?([diouxXeEfFgGaAcCsSp@%])/g) {
                my ($spec, $len, $conv) = ($&, $1 // "", $2);
                if ($conv =~ /^[di]$/ && $len !~ /^(?:l|ll|q|z|t|j)$/) {
                    print "$ARGV:$line: String(format: \"$fmt\") uses $spec — use an l-modified form (%l$conv) for a Swift Int\n";
                }
            }
        }
    '); then
    echo "  ✗ inline String(format:) check could not run (dir: $swift_dir)"
    exit 1
fi
if [ -n "$bad_inline" ]; then
    echo "$bad_inline" | head -5
    echo "  ✗ inline String(format:) literal with a 32-bit signed specifier — use %ld / %02ld for a Swift Int"
    status=1
else
    echo "  ✓ inline String(format:) literals: 64-bit signed integer specifiers"
fi

exit "$status"
