# ROADMAP — Ultra-Deep 2026-08-02 full
## P0 — same PR / security transport
- [ ] `ARCH-ATL-001` UpdateChecker bypasses Core HTTPClient for DMG download
- [ ] `BP-HYD-001` CostEstimator nested unstructured Tasks break cancel
- [ ] `BP-HYD-002` OpencodeScanner never checks cancellation
- [ ] `BP-HYD-003` Vendor refresh Tasks uncancelled overlap
- [ ] `BUG-ART-001` Settings writes notify_at as quoted strings; load falls back to defaults
- [ ] `BUG-ART-002` refresh() clobbers prior outcome before capture on failure
- [ ] `CQ-FOR-001` Disk pin silently overrides PinBaseline
- [ ] `N1-NEX-001` CostEstimator nested Tasks break scanner cancellation
- [ ] `N1-NEX-002` OpencodeScanner double-scans DB without cancel
- [ ] `N1-NEX-003` CodexSessionScanner lacks ScanMemo
- [ ] `RACE-HER-001` UsageHistoryStore.compact releases lock before rewrite
- [ ] `RACE-HER-002` VendorViewModel.refresh never cancels prior Task
- [ ] `RACE-HER-003` OAuth refreshAndWriteBack lacks single-flight
- [ ] `RACE-HER-004` KeychainCredentialReader multi-lock pending drop race
- [ ] `RACE-HER-005` KeychainPromptSuppressor allowed∩suppressed race
- [ ] `SEC-SEN-001` On-disk pin file overrides PinBaseline (pin poisoning)
- [ ] `SEC-SEN-002` Update DMG downloaded without integrity check via URLSession.shared
- [ ] `SEC-SEN-003` TLS pinning off by default; PinBaseline unused until opt-in
- [ ] `SEC-SEN-004` Unrestricted codex_auth_path redirects OAuth writeBack
- [ ] `SEC-SEN-005` Unrestricted keychain_service retargets Claude OAuth item
- [ ] `TEST-ARG-001` No test that disk pin must not override PinBaseline

## Suggested PR buckets
1. **PR-SEC-PIN** — PinBaseline > store; pin default on; HTTPClient fail-closed; tests
2. **PR-SEC-UPDATE** — checksum+pin DMG path; owner_repo allowlist
3. **PR-SEC-PATH** — codex_auth_path + keychain_service allowlists
4. **PR-BUG-SETTINGS** — notify_at doubleArray + VendorViewModel fallback + maxUtil loading
5. **PR-RACE-CANCEL** — VendorViewModel cancel-on-supersede; history compact lock; OAuth single-flight
6. **PR-PERF-COST** — CostEstimator cancel; Codex ScanMemo; Opencode single-pass+cancel
