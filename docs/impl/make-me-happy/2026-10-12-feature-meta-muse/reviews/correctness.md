# Correctness review — feature/meta-muse (round 1)

**1. Every DONE implemented?** Yes. All 12 tasks are in the diff (`cab15ce...HEAD`, slices `6dcc67c`/`7b26e30`/`c8592e7` + merges): `VendorId.meta`/`MetaSnapshot` (T-001), `MetaConfig` + snippet + `config.example.toml` (T-002), `MuseSessionScanner` + `Paths` (T-003), `CostEstimator` wiring (T-004), `MetaCredentialReader` (T-005), `MetaWireTypes` (T-006), `MetaProvider` over `CachedFetch` with 4 `checkCancellation()` points + validate section (T-007), `AppEnvironment` (T-008), card rows + `shortLabel` "MUSE" (`MenuBarLabelView.swift:103`) (T-009), Settings section (T-010), 11 keys × en/pt-BR/es (T-011), README + AGENTS scanner row (T-012).

**2. Real red→green tests?** Code tasks: yes, verified in files — 34 new `@Test`s with concrete `#expect`s, e.g. `golden_semantics` (4188 = 52304−48116, T-003), `inline_wins`/`blocked_degrades` (T-005), `fetch_end_to_end` asserting no `LLM|`/`4242`/email in cache (T-007), `enabled_vendor_ids` (T-008), 3 `SettingsViewModelDiff` meta rows (T-010). Counts reconcile (claimed 40 ≈ 34 + 3 rows + validate asserts). **But** T-012 (docs) claims `tests_added: 1, red_green: true` — no such test exists; T-011 claims 1 added test — none was added (parity is enforced only by the pre-existing `check-source-ratchets.sh`). Also, all 12 `red.output_excerpt`s are identical boilerplate ("compile errors… exit 1"), which cannot be captured evidence for the strings/docs tasks. T-009's `shortLabel`/pin behaviour has no direct test (card gates `payg_renders`/`idle_renders` do).

**3. Immutability (feature)?** Present and real: scanner golden + kind-filter (T-003), mint field-by-field and idle goldens vs `Fixtures.metaMint*` (T-006), no-secret-in-cache (T-007); full suite green protects neighbours.

**4. Slice containment?** Good: three sequential slices, disjoint files except forced exhaustive-switch arms in slice 1 and AGENTS.md; no overlapping rewrites.

**5. Coverage?** `coverage.json` present: 93.17 ≥ floor 90 (`run-meta.coverage_floor`); Oracle: `make validate` green, 1392 tests, 484 runtime assertions.

Fix: correct T-011/T-012 bookkeeping (`tests_added: 0`, `red_green: false`, note ratchet/diff verification) or add real tests; the product code itself needs no change.

VERDICT: REJECT
