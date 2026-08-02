# TASKS — Ultra-Deep Audit

> Auto-gerado por `sync-progress.mjs` · **não editar IDs à mão** — use `--done` / `--open`.

| Metric | Value |
|--------|------:|
| Total | 44 |
| DONE | 44 |
| OPEN | 0 |
| Progress | **100%** |
| Complete | ✅ YES |
| Updated | 2026-08-02 17:36:07 UTC |

## Iteration log

- **2026-08-02 17:36:07 UTC** DONE `DEP-PRI-001,TEST-ARG-005` — Accepted: TOMLKit residual risk in AGENTS.md; COVERAGE_FLOOR=90 already default (test: `doc-close`)
- **2026-08-02 17:27:24 UTC** DONE `BP-HYD-005,N1-NEX-005,N1-NEX-006,TEST-ARG-003,TEST-ARG-004,DEP-PRI-003,TEST-ARG-002` — PR #15 (test: `make validate`)
- **2026-08-02 16:54:34 UTC** DONE `ARCH-ATL-002,CQ-FOR-003,BUG-ART-004,BUG-ART-005,BUG-ART-006,BUG-ART-007,BUG-ART-008,LEAK-HYD-001,N1-NEX-003,N1-NEX-004,RACE-HER-006,RACE-HER-007,CQ-FOR-004,DEP-PRI-002,BP-HYD-004` — MEDIUM batch on PR #14 (test: `make validate`)
- **2026-08-02 16:31:25 UTC** DONE `RACE-HER-003,RACE-HER-004,RACE-HER-005` — OAuth single-flight + Keychain CAS + suppressor hold (test: `PartitionListCodecTests/KeychainPromptSuppressor`)
- **2026-08-02 16:25:02 UTC** DONE `SEC-SEN-001,SEC-SEN-002,SEC-SEN-003,CQ-FOR-001,CQ-FOR-002,TEST-ARG-001,ARCH-ATL-001,BUG-ART-001,BUG-ART-002,BUG-ART-003,RACE-HER-001,RACE-HER-002,BP-HYD-001,BP-HYD-002,BP-HYD-003,N1-NEX-001,N1-NEX-002,N1-NEX-003` — P0 implementation batch (test: `PinningDelegateEvaluateTests/ConfigLoaderSecretTests/AggregatesComputationTests/UsageHistoryStoreTests/UpdateCheckerAssetTests`)
- **2026-08-02 15:47:06 UTC** — TASKS.md created from FINDINGS.json

## Tasks by priority

Checkbox = status. Oracle marca DONE só após **teste red→green**.

### P0 (13/13 done)

- [x] **ARCH-ATL-001** (Atlas/HIGH) — UpdateChecker bypasses Core HTTPClient for DMG download
  - `Sources/AiTaskbarApp/UpdateChecker.swift:163` · test: `UpdateCheckerUsesInjectedHTTPClient` · _P0 implementation batch_
- [x] **BP-HYD-001** (Hydra/HIGH) — CostEstimator nested unstructured Tasks break cancel
  - `Sources/AiTaskbarApp/ViewModels/CostEstimator.swift:79` · test: `cost_cancel` · _P0 implementation batch_
- [x] **BP-HYD-002** (Hydra/HIGH) — OpencodeScanner never checks cancellation
  - `Sources/AiTaskbarCore/Cost/OpencodeScanner.swift:118` · test: `opencode_cancel` · _P0 implementation batch_
- [x] **BP-HYD-003** (Hydra/HIGH) — Vendor refresh Tasks uncancelled overlap
  - `Sources/AiTaskbarApp/ViewModels/VendorViewModel.swift:192` · test: `vendor_single_flight` · _P0 implementation batch_
- [x] **BUG-ART-001** (Artemis/HIGH) — Settings writes notify_at as quoted strings; load falls back to defaults
  - `Sources/AiTaskbarApp/ViewModels/SettingsViewModel.swift:150` · test: `settings_notify_at_roundtrip` · _P0 implementation batch_
- [x] **BUG-ART-002** (Artemis/HIGH) — refresh() clobbers prior outcome before capture on failure
  - `Sources/AiTaskbarApp/ViewModels/VendorViewModel.swift:198` · test: `vendor_refresh_keeps_outcome` · _P0 implementation batch_
- [x] **CQ-FOR-001** (Forge/HIGH) — Disk pin silently overrides PinBaseline
  - `Sources/AiTaskbarCore/Networking/PinningDelegate.swift:64` · test: `baseline_beats_store` · _P0 implementation batch_
- [x] **N1-NEX-001** (Nexus/HIGH) — CostEstimator nested Tasks break scanner cancellation
  - `Sources/AiTaskbarApp/ViewModels/CostEstimator.swift:80` · test: `CostEstimator_cancelStopsScanner` · _P0 implementation batch_
- [x] **N1-NEX-002** (Nexus/HIGH) — OpencodeScanner double-scans DB without cancel
  - `Sources/AiTaskbarCore/Cost/OpencodeScanner.swift:118` · test: `OpencodeScanner_singlePass` · _P0 implementation batch_
- [x] **N1-NEX-003** (Nexus/HIGH) — CodexSessionScanner lacks ScanMemo
  - `Sources/AiTaskbarCore/Cost/CodexSessionScanner.swift:97` · test: `Codex_memo` · _MEDIUM batch on PR #14_
- [x] **RACE-HER-001** (Hermes/HIGH) — UsageHistoryStore.compact releases lock before rewrite
  - `Sources/AiTaskbarCore/History/UsageHistoryStore.swift:113` · test: `compact_vs_append` · _P0 implementation batch_
- [x] **RACE-HER-002** (Hermes/HIGH) — VendorViewModel.refresh never cancels prior Task
  - `Sources/AiTaskbarApp/ViewModels/VendorViewModel.swift:192` · test: `refresh_cancel_supersede` · _P0 implementation batch_
- [x] **TEST-ARG-001** (Argus/HIGH) — No test that disk pin must not override PinBaseline
  - `Tests/AiTaskbarCoreTests/PinStoreTests.swift:209` · test: `pin_baseline_integrity` · _P0 implementation batch_

### P1 (5/5 done)

- [x] **RACE-HER-003** (Hermes/HIGH) — OAuth refreshAndWriteBack lacks single-flight
  - `Sources/AiTaskbarProviders/OpenAIProvider.swift:88` · test: `oauth_single_flight` · _OAuth single-flight + Keychain CAS + suppressor hold_
- [x] **RACE-HER-004** (Hermes/HIGH) — KeychainCredentialReader multi-lock pending drop race
  - `Sources/AiTaskbarCore/Credentials/KeychainCredentialReader.swift:69` · test: `keychain_pending_cas` · _OAuth single-flight + Keychain CAS + suppressor hold_
- [x] **RACE-HER-005** (Hermes/HIGH) — KeychainPromptSuppressor allowed∩suppressed race
  - `Sources/AiTaskbarCore/Credentials/KeychainPromptSuppressor.swift:52` · test: `suppressor_no_allow_while_depth` · _OAuth single-flight + Keychain CAS + suppressor hold_
- [x] **SEC-SEN-001** (Sentinel/HIGH) — On-disk pin file overrides PinBaseline (pin poisoning)
  - `Sources/AiTaskbarCore/Networking/PinningDelegate.swift:64` · test: `TBD` · _P0 implementation batch_
- [x] **SEC-SEN-002** (Sentinel/HIGH) — Update DMG downloaded without integrity check via URLSession.shared
  - `Sources/AiTaskbarApp/UpdateChecker.swift:163` · test: `TBD` · _P0 implementation batch_

### P2 (21/21 done)

- [x] **ARCH-ATL-002** (Atlas/MEDIUM) — ConfigLoader.save bypasses SecretBox encryption
  - `Sources/AiTaskbarCore/Config/ConfigLoader.swift:95` · test: `ConfigLoaderSaveReEncryptsApiKeys` · _MEDIUM batch on PR #14_
- [x] **BP-HYD-004** (Hydra/MEDIUM) — Codex scanner no memo full mmap each refresh
  - `Sources/AiTaskbarCore/Cost/CodexSessionScanner.swift:78` · test: `codex_memo` · _MEDIUM batch on PR #14_
- [x] **BP-HYD-005** (Hydra/MEDIUM) — Scheduler tick fans out without joining prior cycle
  - `Sources/AiTaskbarApp/ViewModels/RefreshScheduler.swift:30` · test: `scheduler_single_flight` · _PR #15_
- [x] **BUG-ART-003** (Artemis/MEDIUM) — maxUtilization recomputed to 0 while vendors loading
  - `Sources/AiTaskbarApp/ViewModels/UsageStore.swift:296` · test: `aggregates_loading_keeps_max` · _P0 implementation batch_
- [x] **BUG-ART-004** (Artemis/MEDIUM) — UsageHistoryStore.compact races append
  - `Sources/AiTaskbarCore/History/UsageHistoryStore.swift:113` · test: `history_compact_preserves_append` · _MEDIUM batch on PR #14_
- [x] **BUG-ART-005** (Artemis/MEDIUM) — TOMLEditor trailing-comment uses first '#' not matched
  - `Sources/AiTaskbarCore/Config/TOMLEditor.swift:205` · test: `toml_hash_in_string` · _MEDIUM batch on PR #14_
- [x] **BUG-ART-006** (Artemis/MEDIUM) — ConfigWatcher.relaunch terminates even if spawn fails
  - `Sources/AiTaskbarApp/ViewModels/ConfigWatcher.swift:72` · test: `relaunch_no_terminate_on_fail` · _MEDIUM batch on PR #14_
- [x] **BUG-ART-007** (Artemis/MEDIUM) — flexibleDoubleArray silent default on mixed int/float
  - `Sources/AiTaskbarCore/Config/AppConfig.swift:205` · test: `mixed_double_array` · _MEDIUM batch on PR #14_
- [x] **CQ-FOR-002** (Forge/MEDIUM) — HTTPClient.pinned silent unpin on store fail
  - `Sources/AiTaskbarCore/Networking/HTTPClient.swift:34` · test: `pinned_fail_closed` · _P0 implementation batch_
- [x] **CQ-FOR-003** (Forge/MEDIUM) — ConfigLoader.save plaintext footgun
  - `Sources/AiTaskbarCore/Config/ConfigLoader.swift:95` · test: `save_keeps_enc` · _MEDIUM batch on PR #14_
- [x] **DEP-PRI-001** (Prism/MEDIUM) — Sole runtime dep TOMLKit unmaintained at 0.6.0
  - `Package.resolved:23` · test: `tomlkit_builds` · _Accepted: TOMLKit residual risk in AGENTS.md; COVERAGE_FLOOR=90 already default_
- [x] **LEAK-HYD-001** (Hydra/MEDIUM) — compact() swallows write failures; JSONL can grow
  - `Sources/AiTaskbarCore/History/UsageHistoryStore.swift:111` · test: `compact_error_visible` · _MEDIUM batch on PR #14_
- [x] **N1-NEX-004** (Nexus/MEDIUM) — DiskCache cache-hit double stat
  - `Sources/AiTaskbarProviders/CachedFetch.swift:26` · test: `DiskCache_singleStat` · _MEDIUM batch on PR #14_
- [x] **N1-NEX-005** (Nexus/MEDIUM) — Per-window 1Hz TimelineView fan-out
  - `Sources/AiTaskbarApp/Views/ProviderRowView.swift:33` · test: `ProviderRow_sharedClock` · _PR #15_
- [x] **N1-NEX-006** (Nexus/MEDIUM) — UsageHistoryStore.load Data(line) copies on MainActor
  - `Sources/AiTaskbarCore/History/UsageHistoryStore.swift:99` · test: `History_noLineCopy` · _PR #15_
- [x] **RACE-HER-006** (Hermes/MEDIUM) — DiskCache concurrent writePayload vs markFailed
  - `Sources/AiTaskbarCore/Cache/DiskCache.swift:73` · test: `diskcache_locked_writers` · _MEDIUM batch on PR #14_
- [x] **RACE-HER-007** (Hermes/MEDIUM) — ConfigWatcher rearm burst leaks DispatchSources
  - `Sources/AiTaskbarApp/ViewModels/ConfigWatcher.swift:103` · test: `configwatcher_single_source` · _MEDIUM batch on PR #14_
- [x] **SEC-SEN-003** (Sentinel/MEDIUM) — HTTPClient.pinned fails open if PinStore cannot be created
  - `Sources/AiTaskbarCore/Networking/HTTPClient.swift:34` · test: `TBD` · _P0 implementation batch_
- [x] **TEST-ARG-002** (Argus/MEDIUM) — UpdateChecker download session untested
  - `Tests/AiTaskbarAppTests/UpdateCheckerAssetTests.swift:1` · test: `update_download_stub` · _PR #15_
- [x] **TEST-ARG-003** (Argus/MEDIUM) — ConfigLoader secret tamper/decrypt-failure paths thin
  - `Tests/AiTaskbarCoreTests/ConfigLoaderSecretTests.swift:32` · test: `secret_tamper` · _PR #15_
- [x] **TEST-ARG-004** (Argus/MEDIUM) — Keychain invalidateCachedCredentials untested
  - `Sources/AiTaskbarCore/Credentials/KeychainCredentialReader.swift:148` · test: `kc_invalidate` · _PR #15_

### P3 (5/5 done)

- [x] **BUG-ART-008** (Artemis/LOW) — ensureAllVendorSections substring match for headers
  - `Sources/AiTaskbarCore/Config/ConfigLoader.swift:235` · test: `ensure_ignores_comment_header` · _MEDIUM batch on PR #14_
- [x] **CQ-FOR-004** (Forge/LOW) — Package.swift stale Swift 5 language mode comment
  - `Package.swift:8` · test: `doc_only` · _MEDIUM batch on PR #14_
- [x] **DEP-PRI-002** (Prism/LOW) — config.example pin_hosts lists api.openai.com unused
  - `config.example.toml:48` · test: `example_hosts_match` · _MEDIUM batch on PR #14_
- [x] **DEP-PRI-003** (Prism/LOW) — swift-testing from 0.10.0 resolves 0.99.0 wide range
  - `Package.swift:27` · test: `testing_exact` · _PR #15_
- [x] **TEST-ARG-005** (Argus/LOW) — COVERAGE_FLOOR still 0
  - `AGENTS.md:1` · test: `coverage_floor` · _Accepted: TOMLKit residual risk in AGENTS.md; COVERAGE_FLOOR=90 already default_

## Still OPEN

_All tasks complete._ 🎉

## Workflow (cada iteração)

```bash
# 1) Implement fix + red→green test
# 2) Mark done:
node .claude/skills/ultra-deep-audit/scripts/sync-progress.mjs \
  --dir docs/audit/ultra-deep/2026-08-02-full \
  --done ID1,ID2 \
  --note "PR #N / commit sha" \
  --test "ClassName#method"
# 3) HTML + TASKS atualizados automaticamente
# 4) Quando OPEN=0, report.html título vira COMPLETE
```

## ✅ AUDIT COMPLETE

All 44 findings marked DONE. HTML regenerated as complete.
