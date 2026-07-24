#!/usr/bin/env python3
"""Re-check the two wire invariants CodexSessionScanner.swift relies on.

The scanner's doc comment claims two things about Codex's rollout format.
Both are observed behaviour, not a published contract, so they can drift the
moment OpenAI changes the Codex CLI. This script re-runs the check against
whatever rollouts are on the machine, so a reader can verify the claim instead
of trusting it — the audit that prompted this file found the first invariant
stated absolutely when it actually holds for 626 of 628 events.

    ./scripts/verify-codex-invariants.py [sessions_dir]

Exits non-zero if an invariant fails in a way the scanner does NOT already
account for.
"""
import json
import pathlib
import sys
from collections import Counter

sessions = pathlib.Path(sys.argv[1] if len(sys.argv) > 1
                        else pathlib.Path.home() / ".codex/sessions")
if not sessions.is_dir():
    print(f"no sessions directory at {sessions}")
    sys.exit(0)

files = sorted(sessions.rglob("*.jsonl"))
events = 0
split_ok = 0
split_violations = []          # total_tokens != input + output
zero_split = []                # the known-and-handled subset of the above
cached_over_input = []
delta_matches = 0
delta_mismatches = []

for f in files:
    running = Counter()
    final_total = None
    for line in f.open():
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        payload = obj.get("payload") or {}
        if payload.get("type") != "token_count":
            continue
        info = payload.get("info") or {}
        last = info.get("last_token_usage")
        if info.get("total_token_usage"):
            final_total = info["total_token_usage"]
        if not last:
            continue
        events += 1
        i = last.get("input_tokens", 0)
        c = last.get("cached_input_tokens", 0)
        o = last.get("output_tokens", 0)
        t = last.get("total_tokens", 0)

        # Invariant 1: total == input + output (cached ⊆ input, reasoning ⊆ output)
        if t == i + o:
            split_ok += 1
        else:
            where = f"{f.name} @{obj.get('timestamp')}"
            if i == 0 and o == 0:
                zero_split.append((where, t))   # scanner drops + counts these
            else:
                split_violations.append((where, i, o, t))
        if c > i:
            cached_over_input.append((f.name, i, c))
        for k, v in last.items():
            running[k] += v or 0

    # Invariant 2: summing the per-turn deltas reproduces the session total.
    #
    # Compared over the fields the scanner actually BILLS, not every key.
    # `total_tokens` is excluded deliberately: Codex adds the all-zero-split
    # events (see invariant 1) into the session's running `total_tokens` while
    # contributing nothing to the input/output breakdown, so that one field
    # legitimately drifts by exactly the sum of those events. The scanner never
    # reads `total_tokens`, so including it here would report a failure that
    # has no effect on any number we display.
    BILLED = ("input_tokens", "cached_input_tokens", "output_tokens")
    if final_total and running:
        if all(running.get(k, 0) == final_total.get(k, 0) for k in BILLED):
            delta_matches += 1
        else:
            delta_mismatches.append((
                f.name,
                {k: running.get(k, 0) for k in BILLED},
                {k: final_total.get(k, 0) for k in BILLED},
            ))

print(f"files: {len(files)}   token_count events: {events}")
print(f"[1] total == input + output : {split_ok}/{events} ok")
print(f"    all-zero split (dropped and counted by the scanner): {len(zero_split)}")
for w, t in zero_split:
    print(f"      - {w}  total_tokens={t}")
if split_violations:
    print(f"    UNACCOUNTED violations: {len(split_violations)}")
    for w, i, o, t in split_violations[:10]:
        print(f"      ! {w}  input={i} output={o} total={t}")
print(f"    cached > input: {len(cached_over_input)}")
print(f"[2] sum(last) == final total : {delta_matches}/{delta_matches + len(delta_mismatches)} files ok")
for name, got, want in delta_mismatches[:5]:
    print(f"      ! {name}\n        got  {got}\n        want {want}")

bad = bool(split_violations or cached_over_input or delta_mismatches)
print("\nFAIL — an invariant the scanner relies on no longer holds."
      if bad else "\nOK — both invariants hold (modulo the counted all-zero events).")
sys.exit(1 if bad else 0)
