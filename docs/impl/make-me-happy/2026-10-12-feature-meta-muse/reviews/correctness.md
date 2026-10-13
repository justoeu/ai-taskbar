# Correctness review — feature/meta-muse (round 2)

**C-1 (T-012 docs) fixed.** `docs_present` (`Tests/AiTaskbarAppTests/MetaLocalizationDocsTests.swift:32`, commit `25afe2b`) asserts README row/section/`[meta] enabled = false` and the AGENTS `` `MuseSessionScanner` (`~/.local/share/muse/sessions`) `` row plus SDD ref. Non-vacuous: base `cab15ce` README has 0 Muse markers, so reversal-red holds.

**C-2 (T-011 i18n) fixed.** `meta_keys_everywhere` (`MetaLocalizationDocsTests.swift:21`) checks 17 keys x en/pt-BR/es via `LocalizableStrings.defines`; helper has a negative-control test. Verified 17/17/17 at HEAD, 0 at base. `tests_added: 1` now matches one real `@Test` per task.

**C-3 (boilerplate evidence) fixed.** `TASKS.json` red/green excerpts are now per-task factual (slice RED runs, named symbols, reversal notes for T-011/T-012).

**Other axes re-checked.** All 12 DONE remain in the diff; immutability goldens present (T-003 scanner, T-006 mint); slices disjoint; `coverage.json` 93.21 >= floor 90; `tests.json` ok — 1400 passed, 487 runtime assertions.

**Remaining (low, non-blocking): C-4 narrowed.** `rotating_skips_windowless` (`MetaCardTests.swift:26`, T-009) now directly tests rotating/pin behaviour; only the literal `shortLabel == "MUSE"` has no naming test — UI smoke territory.

VERDICT: APPROVE
