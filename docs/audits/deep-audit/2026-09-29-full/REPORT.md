# Deep Audit Report

> **Progresso:** 162 resolvidos · 16 refutados · 10 aceitos · 0 abertos (100% fechado) · atualizado 2026-09-30

**Projeto:** `ai-taskbar` - **versao** `0.23.6` (Makefile) - **branch** `audit/deep-audit-2026-09-29` - head at start `656075a`

**Rodada:** 2026-09-29 - modo `full` - profundidade `deep` - esforco `max` - base `origin/main`

## Pipeline executed

- Wave A (overlapped with B, not strictly sequential): Atlas / security-deep (Cartografo, hunters, panel) / Fluxo
- Wave B: Cronos / Fantasma / Represa / Artemis / Enxame
- Wave C: Aurora / Argus / Prisma
- Wave D: Dedalo / Eco / Laconio / Atena
- Cetico: 3 parallel verifiers (A/B/C) re-checked all 101 non-panel findings from waves A-D
- Ferreiro: fixed the 3 HIGH findings (red, then green, then reversal-checked)
- 3-lens review (Nemesis/CORRECTNESS, Higia/QUALITY, Jano/SCOPE) on each fix, via review-verify
- Escriba (this report): consolidation, no code touched

## Security-deep panel (independent from the general lenses)

- Cartografo inventoried 24 components (sec-deep/inventory.json), persisted verbatim by the Maestro because the Cartografo agent had no write tool.
- 15 hunter runs (one per component group, several vendor components grouped per run; each lens is a separate pass, persisted per component x lens as sec-deep/hunter-*.json) plus 1 dedicated secrets sweep over the working tree and git history (hunter-whole-repo-secrets-crypto-secrets.json: 0 real secrets found).
- effort=max triggered a 2nd adversarial pass over survivors (hunter-pass2-*), which produced 3 new candidates (C13-C15), each given its own 3-vote panel like the rest.
- Total: 15 candidates, 45 vote files (15 x 3 voters: REACHABILITY/IMPACT/DEFENSES), verified with sec-verify --require-vote-files.
- sec-deep/coverage.json: verification_status "verified", panel_source "vote-files" (a real panel ran this round, not a placeholder), quorum 2/3, 0 unreviewed candidate sites.
- 5 kept (survived quorum): SEC-CER-001 HIGH, SEC-CER-002 MEDIUM, SEC-CER-003/004/005 LOW.
- 10 dropped below quorum (C1, C2, C3, C4, C5, C7, C8, C9, C10, C12 - see dropped_sample in coverage.json), e.g. temp-file umask window before chmod, TLS-pin opt-in gap, mmap SIGBUS on truncated JSONL, several Int(Double) traps on hostile vendor payloads, AtomicFileWrite preserving a looser mode on overwrite.

## Cetico verification (all 101 non-panel findings)

- 16 REFUTADO, outcome refutado, each with cited counter-evidence (e.g. CPX-DED-001/002, TEST-ARG-010/013, BEST-ATE-002/005/007, BP-REP-004/005, RACE-CRO-005/006/009, N1-ENX-001/002/003, DUP-ECO-003).
- 9 PLAUSIVEL, 74 CONFIRMADO (rest of the non-refuted set).
- HIGH claims downgraded (original severity in severity_original, current in severity):

  | id | original -> final | verdict |
  |---|---|---|
  | BUG-ART-003 | HIGH -> MEDIUM | CONFIRMADO |
  | PERF-FLU-001 | HIGH -> MEDIUM | CONFIRMADO |
  | CQ-AUR-001 | HIGH -> MEDIUM | CONFIRMADO |
  | TEST-ARG-001 | HIGH -> MEDIUM | CONFIRMADO |
  | TEST-ARG-002 | HIGH -> MEDIUM | CONFIRMADO |
  | TEST-ARG-003 | HIGH -> LOW | CONFIRMADO |
  | RACE-CRO-001 | HIGH -> LOW | CONFIRMADO |
  | RACE-CRO-002 | HIGH -> LOW | PLAUSIVEL |
  | BP-REP-001 | HIGH -> LOW | CONFIRMADO |
  | BP-REP-002 | HIGH -> LOW | CONFIRMADO |

- Methodology disclosure (honest, not hidden): Cetico B executed the user's local agy CLI (~/.local/bin/agy) once, outside the read-only brief, solely to measure stdout/stderr sizes for a Gemini/Antigravity-related claim. Cetico A ran count-only scripts over local Claude transcripts (no transcript content was printed, only counts). Both are noted here because a verifier stepping outside "read-only" is itself worth flagging even when the result was used correctly.

## Fixed HIGH (3/3) - red, green, reversal, re-proven, 3-lens reviewed

| id | title | commit | tests (must fail on revert) |
|---|---|---|---|
| BUG-ART-001 | Claude cost roughly doubled: transcript lines summed with no message.id+requestId dedup | ff933f0 | ClaudeSessionScannerTests#duplicate_key_in_one_file_counts_once,duplicate_key_keeps_larger_output,duplicate_key_across_files_counts_once,duplicate_key_across_files_with_memo_replay,scan_dedups_within_data |
| BUG-ART-002 | Analytics folded opencode's OpenAI dollars into the Codex cost estimate (forbidden by CLAUDE.md, opencode is a client, not a vendor) | 956d06d | AnalyticsOpencodeMerge#openai_dollars_not_added,zai_dollars_not_added,opencode_only_vendor_zero_dollars,openai_tokens_merged |
| SEC-CER-001 | Update DMG accepted with no integrity anchor outside the release and no quarantine flag; Gatekeeper never checked it | d3bcee6 | UpdateCheckerDownloadTests#missing_checksum_fails_closed,downloaded_dmg_is_quarantined,verifier_rejects,verifier_accepts |

All three: verdict approved, panel_source "vote-files", test_reversal_checked true.

Review rounds - where the Ferreiro needed a second pass:
- BUG-ART-001: approved round 1, all three lenses APROVA first try.
- BUG-ART-002: round-1 QUALITY = MUDANCAS (Higia). The fix correctly stopped re-pricing opencode dollars, but left AnalyticsStore.computedToday/computedLast7 always mapped to 0.0, dead ceremony under a name that now lies about what it does. Round-2 fix addressed it; all three lenses APROVA on round 2 (reviews/votes-round1/BUG-ART-002-QUALITY.json, reviews/BUG-ART-002.json).
- SEC-CER-001: round-1 QUALITY = MUDANCAS (Higia). TeamSignatureDMGVerifier.runHdiutil was a near line-for-line copy (about 30 lines: pipe, semaphore-signaled terminationHandler, background drain, deadline+SIGKILL) of the pre-existing SecurityToolCredentialReader.runTool, already diverging (missing the original's race-window check on a clean exit landing on the deadline). Round-2 fix extracted the shared logic; approved on round 2.
- Metric: 2 of 3 fixes (67%) needed one changes_requested round before approval, both on the QUALITY lens, both for the same failure mode (leftover/duplicated machinery from a correct fix); worth watching for the Ferreiro going forward.
- No waived reviews this round (review.waived count = 0 across all 115 findings); nothing was dismissed without panel sign-off.

## make validate (final state after the 3 HIGH fixes)

Reported green: 853 tests / 111 suites, 3 known issues (intentional negative controls, the Boolean-assertion-guard self-tests), coverage 91.74% on AiTaskbarCore+AiTaskbarProviders (floor 90%, baseline before this round 91.53%), 0 warnings outside the allowlisted classic-Keychain deprecations, smoke launch OK, permission audit OK (Application Support/ai-taskbar dir 0700, config.toml 0600, codex auth.json 0600).

One transient, unnamed test failure (2 issues) was observed once during a Ferreiro run on BUG-ART-002; a follow-up full swift test run passed 836/836 and a re-run of make validate was green. It was not silently dropped; it is tracked as TEST-MAE-002 (likely related to TEST-ARG-007's real api.github.com call plus a 50 ms wall-clock window): "Make the gate print failing test names; fix TEST-ARG-007; track flaky tests."

## Dependencies research (deps-latest.json)

- 1 package consulted (SPM only: LebJe/TOMLKit, the single runtime dependency).
- 1 up to date, 0 behind latest stable, 0 query errors (runner_errors: []).
- TOMLKit declared 0.6.0, latest stable 0.6.0, bump none; matches the CLAUDE.md-documented accepted residual risk (DEP-PRI-001: unmaintained but local-file-only, no network surface, reproducible pin).
- update_map.batches contains only the stack-detected entry at priority info (no actionable update batch this round). TASKS.md's "Roadmap de libs / dependencias" section reflects this: "Toda lib pesquisada esta no latest stable." The Roadmap section in report.html mirrors the same state.
- Since summary.errors is 0, the "0 outdated" figure is a real total, not a floor.

## Findings by severity (post-verification)

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 3 (all resolved) |
| MEDIUM | 10 (all open) |
| LOW | 71 |
| INFO | 31 |
| Total | 115 |

## Findings by outcome

| Outcome | Count |
|---|---|
| resolved | 3 |
| open | 96 |
| refutado | 16 |
| aceito (accepted) | 0 |

(refutado and aceito tracked separately, as required; no accepted/waived risk decisions were made this round.)

## Findings by lens

classic_bugs 16, tests 16, race 11, best_practices 10, memleak 9, verbosity 8, architecture 7, quality 6, backpressure 6, duplication 6, security 5, complexity 5, deps 4, performance 3, nplus1 3

## Label audit (accepted sanity check)

lint-findings gate result: 115 achados, 96 aberto, 3 resolvido, 16 refutado, 0 aceito, 0 bloqueando PR - OK. There are zero accepted entries this round, so there is nothing to audit for silent risk-acceptance disguised as a decision, and nothing was rebaixado (downgraded) by lint-findings --fix for missing required fields.

## Open MEDIUMs (did not fit this round - user scope was "fix HIGH only")

| id | one-liner | proposed plan |
|---|---|---|
| ARCH-ATL-001 | Hard-coded pt-BR disclaimer strings built inside Providers wire types; matching L10n keys are dead | Replace disclaimer: String? on GeminiSnapshot/XAISnapshot with a structured flag resolved by the view via L10n |
| BUG-ART-003 | Monthly analytics timeframe shows the 7-day cost, not a 30-day figure | Add usdLast30Days to CostEstimate from the scanners; never reuse usdLast7Days for .monthly |
| BUG-ART-004 | OpenRouter 30-day activity and xAI billing-cycle spend both stored as usdLast7Days | Decode each activity item's date, sum only the true last 7 days; give xAI cycle spend its own labeled field |
| BUG-ART-005 | Repeated token_count events with unchanged total_token_usage are billed again | Track the previous total per file; skip an event whose total did not increase |
| BUG-ART-006 | The "last 7 days" window actually spans 8 calendar days and disagrees with opencode's window | Use cal.date(byAdding: .day, value: -6, ...) everywhere, including opencode |
| CQ-AUR-001 | Hardcoded pt-BR error/disclaimer text ships to every locale (Gemini + Grok) | Route through L10n.localizedString for the two disclaimer keys |
| PERF-FLU-001 | AnalyticsStore.recompute() does synchronous multi-vendor disk I/O on MainActor, twice per cost-estimate cycle | Merge the two CostEstimator assignments into one update; move the I/O off MainActor |
| SEC-CER-002 | Oversized utilization value survives into 90-day history and replays into Int() on the analytics busiest-day label | Clamp and finite-check utilization at UsageWindow construction and in UsageHistoryStore.append/load |
| TEST-ARG-001 | AtomicFileWrite overwrite keeps the old file mode (0644 survives a 0o600 write); untested | Add a test pre-creating dest at 0644; fix via rename(2) or explicit final chmod |
| TEST-ARG-002 | canPersistCredentials guard against rotating a security-tool-fallback credential is never tested at provider level | Add mock canPersistCredentials; E2E test asserting 0 refresh hits and empty write-back when false |

## Notable

- LEAK-FAN-004 ("Downloaded DMG temp file is not deleted when the status/size/checksum check fails"): the SEC-CER-001 fix touched the same download path and changed some of the temp-file cleanup code as a side effect, but the finding stays open: there is no red-first test in this round that proves the leak is closed on every throw path (non-2xx, size mismatch, checksum mismatch). Do not read this as fixed.
- New findings queued for next round (agent-maestro-review-followups.json, already merged into FINDINGS.json with IDs, raw_findings: 115 includes them): BP-MAE-001, BUG-MAE-001, CQ-MAE-001, DUP-MAE-001, LEAK-MAE-001, TEST-MAE-001, TEST-MAE-002, DEP-MAE-001, TEST-MAE-003; all raised by the 3-lens review panel while validating the 3 fixes (origin: "new_findings from the 3-lens code review panel").
- Version: product code changed (3 fix commits on audit/deep-audit-2026-09-29) but nothing was bumped by hand; per CLAUDE.md the auto-tag workflow bumps on merge to main. Nothing was pushed and no PR was opened this round.

## Verdict

The HIGH-severity surface this round was real but narrow: two cost-accounting bugs (Claude transcript double-counting, opencode dollars leaking into Codex's total) and one integrity gap in the update path (DMG installed with no anchor outside the release itself and no quarantine flag). All three are now fixed, each with a red-before/green-after test that fails on git revert, and each cleared a 3-lens review; two of them only after a legitimate changes_requested round that caught real leftover debt (a renamed-but-still-zero computation, a roughly 30-line duplicated subprocess-kill routine), not rubber-stamped. The security-deep panel ran a genuine 3-voter quorum over 15 candidates (not a placeholder; panel_source "vote-files"), kept 5, and correctly dropped 10 speculative ones below quorum. Cetico's pass was substantive: 16 refutations with cited evidence and 10 HIGH claims correctly downgraded to MEDIUM/LOW on inspection, which is a healthy signal that the original wave agents over-called severity rather than under-called it. Coverage stayed above floor and even rose slightly (91.53% to 91.74%). Nothing was accepted or waived; the 96 open findings (10 MEDIUM, 71 LOW, 15 INFO) are genuinely open, not risk decisions in disguise, and the single dependency in the tree (TOMLKit) is confirmed current. The core is well hardened for this round's HIGH-only scope; the MEDIUM backlog (mostly cost/window-accounting edge cases and one more crash-hardening item, SEC-CER-002) is the honest next target, not a hidden gap.

---

## Remediação (fechamento pós-round-1, 2026-09-29)

> Esta seção cobre o que aconteceu **depois** do fechamento acima (commit `dfca407`,
> escopo "corrigir só os HIGH"). O coordenador manteve a rodada aberta e rodou 21
> lotes de remediação (B1..B21) sobre o backlog de MEDIUM/LOW/INFO, mais os
> follow-ups que o próprio painel de revisão levantou a cada lote, mais 1 item
> reportado pelo usuário. `FINDINGS.json` (188 achados) é a fonte da verdade para
> todo número abaixo; nada aqui foi inferido fora dele e do histórico git.

**Projeto:** `ai-taskbar` · **versão** `0.23.6` (Makefile) · **branch** `audit/deep-audit-2026-09-29` · head final `2aef89b`

### Estado final por severidade x desfecho

| Severidade | Total | Resolvido | Aceito | Refutado | Aberto |
|---|---|---|---|---|---|
| CRITICAL | 0 | 0 | 0 | 0 | 0 |
| HIGH | 3 | 3 | 0 | 0 | 0 |
| MEDIUM | 11 | 11 | 0 | 0 | 0 |
| LOW | 117 | 114 | 3 | 0 | 0 |
| INFO | 57 | 34 | 7 | 16 | 0 |
| **Total** | **188** | **162** | **10** | **16** | **0** |

`refutado` (16) e `aceito` (10) são KPIs separados — nunca somados. Nenhum dos 16
refutados veio das remediações B1-B21: todas as 16 refutações aconteceram no
Cetico do round 1 (ver seção acima) e permanecem inalteradas.

`lint-findings.mjs --dir PACK --gate` (sem `--fix`, achados já corretos):

```
188 achados · 0 aberto · 162 resolvido · 16 refutado · 10 aceito · 0 bloqueando PR
severidade: CRITICAL 0 · HIGH 3 · MEDIUM 11 · LOW 117 · INFO 57
OK (gate de fechamento passou)
```

### MEDIUM resolvido nesta fase (11/11), com destaque para o item reportado pelo usuário

Todos os 11 MEDIUM abertos ao fim do round 1 (mais 2 que entraram como MEDIUM
durante a remediação) foram fechados. O único reportado pelo usuário, não por um
agente:

- **UPDATE-SCHED-001** — "Update check loop sleeps a fixed 86400 s after a launch
  check that UpdateChecker skips when the last check is < 24 h old, so the real
  gap reaches ~48 h." Corrigido no batch **B17-update-sched**, commit
  **`5f7a4ce`** ("fix(updates): check once per calendar day instead of a fixed
  24 h sleep"): a checagem agora é devida sem checagem prévia, num novo dia
  local, ou após 24 h; o loop dorme até a próxima marca (meia-noite local ou
  +24 h, piso de 60 s) e recalcula a cada rodada. Prova: 14 testes
  (`UpdateCheckDueTests#same_day_waits_for_midnight`, `...previous_day_is_due`,
  `...never_checked_is_due`, `...older_than_a_day_is_due`,
  `...future_last_check_is_capped`, `...delay_has_a_floor`,
  `...dst_start_waits_for_shifted_day_start`, `...dst_start_new_day_is_due`,
  `...dst_end_uses_24h_bound`, `...dst_end_same_day_after_24h_is_due`,
  `...check_if_needed_runs_on_new_day`,
  `RefreshSchedulerTests#update_loop_checks_on_relaunch_next_day`,
  `...update_loop_sleeps_until_next_day`, `...update_loop_not_started_when_disabled`).
  Revisão: aprovado 3/3 (`reviews/UPDATE-SCHED-001.json`, panel_source
  vote-files). Também os 4 MEDIUM `SEC-CER-002/003/004/005` do painel
  security-deep (round 1: sobreviventes de quórum, ainda abertos) foram
  fechados no batch **B3-numeric**.

### LOW: 114 resolvidos, 3 aceitos

117 LOW no total; 114 corrigidos com teste red/green e revisão 3/3, 3 aceitos
como won't-fix (ver tabela de aceites abaixo: `BUG-ART-008`, `BUG-MAE-003`,
`DEP-PRI-003`).

### INFO: 34 resolvidos, 7 aceitos, 16 refutados, 0 abertos

57 INFO no total. Os 16 refutados são os mesmos 16 refutados pelo Cetico no
round 1 (nenhum INFO novo foi refutado na remediação). Os 3 que ficaram
abertos ao fim da rodada — todos `review-followup-r2`, levantados pelo painel
de revisão do último lote (B21) — foram resolvidos em 2026-09-30 no branch
`chore/audit-open-items`, com `make validate` verde. Não passaram pelo painel
de 3 lentes (as 159 correções da rodada, sim):

| id | título | como foi resolvido |
|---|---|---|
| CQ-MAE-025 | Over-long comment line in `check-source-ratchets.sh` | Comentário re-quebrado (os números de linha mudaram desde a auditoria) |
| DUP-MAE-008 | Six App test files copy the same `#filePath` walk-up to read `Localizable.strings` | Helper único `Tests/AiTaskbarAppTests/LocalizableStrings.swift` nas 8 cópias, com controle positivo e negativo próprio (`LocalizableStringsHelperTests`) |
| TEST-MAE-013 | Inline format ratchet (check 4) does not scan `NSString(format:)`, `String(format:locale:)`, `.init(format:)`, formats held in a `let`, multi-line literals, or `%x` fed a Swift `Int` | A regra 4 cobre `NSString(format:)`, `String.init(format:)`, `.init(format:)` inferido, `String(format:locale:)`, `localizedStringWithFormat` e literais `"""`, com plantas no self-test. Fora por decisão: formato em `let` (não é literal na chamada) e `%x` (32 bits de propósito para valores de largura fixa) |

### Aceites (won't-fix) — 10, todos ratificados, nenhum silencioso

Toda entrada `accepted` carrega `accept.type`, `accept.what`, `accept.consequence`
e `accept.reopen_if` em `FINDINGS.json` — nenhuma foi apenas marcada e
esquecida. Todas ratificadas pela mesma política: *"user won't-fix policy
relayed by coordinator 2026-09-29 (pending product-owner confirmation)"* — ou
seja, a decisão de não corrigir veio do usuário via coordenador, mas ainda
aguarda confirmação formal do dono do produto.

| id | sev | tipo | o quê | consequência | reabre se |
|---|---|---|---|---|---|
| BUG-ART-008 | LOW | intencional | Créditos de uso da Anthropic (`extra_usage`) continuam dentro de `windows`, movendo `maxUtilization`/notificações | Um overage perto do teto pode colorir a menu bar mesmo com as janelas do plano baixas | Dono do produto decidir que overage não deve mexer no %, ou relato de usuário confuso |
| BUG-MAE-003 | LOW | sem-correção-disponível | OpenRouter não tem custo de Analytics em nenhuma janela; 30-day activity/uso vitalício ficam só no card | É um número ausente, não errado | Uma captura verbatim de `/api/v1/activity` mostrar campo de data por item |
| DEP-PRI-003 | LOW | trade-off | `select-swift` não tem teto de versão, sempre builda com o Xcode mais novo da imagem | CI pode ficar vermelho sem mudança no repo; DMGs são locais, binário publicado não muda | CI/release passarem a anexar binário publicado, ou CI divergir de `make validate` local por bump de imagem |
| ARCH-MAE-001 | INFO | trade-off | `UsageWindow.label` continua sendo texto de exibição e chave de identidade (ForEach id, chave de notificação) | Duas janelas com o mesmo label colidiriam; renomear um label rearma notificações uma vez | Um vendor emitir duas janelas com o mesmo label, ou labels serem localizados |
| BEST-MAE-001 | INFO | dívida cosmética | `CostWindow` é público mas só o Core usa; `KeyedUsage.usage` é reconstruído a cada leitura | Pequeno custo de CPU em leituras | Um profile mostrar `KeyedUsage.usage` em hot path |
| CQ-MAE-013 | INFO | dívida cosmética | `validate.sh` mistura as linhas do ratchet com sua própria saída colorida | Nenhuma no gate | Saída passar a ser parseada por alguma ferramenta |
| CQ-MAE-020 | INFO | dívida cosmética | `gemini.prefer_antigravity`, `xai.prefer_grok_cli`, `xai.grok_base_url` só mudam editando `config.toml` | Usuário precisa editar o TOML para essas 3; defaults cobrem o caso comum | Um usuário pedir controle na Settings, ou o default mudar |
| CQ-MAE-024 | INFO | dívida cosmética | `send -> deliveryFinished -> tracker` passa 4 valores soltos em vez de uma referência única | Nenhum defeito hoje; um 5º campo futuro poderia ser esquecido em algum call site | Um campo novo for adicionado, ou algo tocar as assinaturas de `unmark`/`delivered`/`park` |
| PERF-MAE-001 | INFO | intencional | `AtomicFileWrite` agora faz fsync em toda escrita, incl. marcadores de erro do `DiskCache` e `ConfigLoader.save` | Poucos ms por escrita, uma vez por refresh/save | Um hitch de MainActor for rastreado até `AtomicFileWrite` |
| TEST-MAE-008 | INFO | intencional | `COVERAGE_FLOOR` vazio cai para 0 (report-only) por expansão de default | Nenhuma em `make validate`/CI | CI/`validate.sh` passarem a enviar um valor vazio |

### Revisão das correções (Nêmesis/Hígia/Jano)

159 correções passaram pelo painel de 3 lentes (CORRECTNESS/QUALITY/SCOPE),
todas com `panel_source: "vote-files"` e 3 votantes reais (não placeholder).
**149 aprovadas de primeira** (3/3 `APROVA` na primeira rodada); **10
precisaram de uma rodada de `MUDANCAS`** antes de aprovar: `BUG-ART-002`,
`SEC-CER-001` (ambas já contadas no round 1, ver acima), mais
`BUG-ART-010`, `RACE-CRO-002`, `RACE-CRO-010`, `TEST-ARG-001`, `BP-REP-003`,
`CQ-MAE-011`, `CQ-MAE-012`, `BUG-MAE-010` na remediação — em todos os 8
casos novos o lens que pediu mudança está registrado em
`reviews/votes-round1/<batch>/<id>-<LENS>.json`. **Nenhuma dispensa
(`review.waived`)** em nenhum dos 159 — zero ocorrências no campo em todo o
`FINDINGS.json`, então não há dispensa silenciosa a relatar.

### Dependências (deps-latest.json) — inalterado desde o round 1

- 1 pacote consultado (SPM: `LebJe/TOMLKit`, única dependência de runtime).
- 1 em dia, 0 atrás do latest stable, 0 erros de consulta (`runner_errors: []`).
- Como `summary.errors` é 0, "0 desatualizado" é total real, não piso.
- `update_map.batches` só tem a entrada `stack-detected` em prioridade `info`
  (nenhum lote de atualização acionável). Isso aparece no Roadmap do
  `report.html` e na seção "Roadmap de libs / dependências" do `TASKS.md`.
- Nenhuma dependência nova entrou durante B1-B21; `deps-latest.json` não foi
  re-executado porque o grafo de pacotes não mudou (nenhum commit tocou
  `Package.swift`/`Package.resolved`).

### Batches de remediação (B1..B21) — commits desde `dfca407`

`dfca407` é o commit que publicou o pack do round 1 (report/findings/tasks).
Todos os commits abaixo vêm depois dele, na ordem em que aconteceram
(`git log --oneline dfca407..HEAD`):

| batch | achados fechados | commit | resumo |
|---|---|---|---|
| B1-analytics | 7 | `9734f63` | Custo mensal correto na Analytics; nada de 30-day/ciclo na Week; modelos não sessões |
| B2-scanners | 8 | `dd0b32a` | Uma janela de 7 dias calendário; eventos Codex rebilled não recontados; somas do opencode seguras |
| B3-numeric | 7 | `1273b30` | Sem `Int(Double)` trapping em número de vendor/credencial/histórico (inclui SEC-CER-002/003/004/005) |
| B4-i18n | 5 | `3baba88` | Avisos/erros de Gemini e Grok estruturados e localizados |
| B5-history (+r2) | 8 | `b2e6d9d` | Carga de histórico de Analytics fora da main; só leituras ao vivo gravadas |
| B6-files-tests (+r2) | 8 | `c5233a2` | 0600 na criação; segredos soltos travados; symlinks recusados; testes mais fortes |
| B7-scheduler | 5 | `36ff002` | Um vendor travado não trava mais o refresh de todos; testes determinísticos |
| B8-updater (+r2) | 8 | `a69b8ba` | Fetches limitados; opt-in de pre-release funcionando; precedência SemVer; sem vazamento de temp |
| B9-bounded-io | 6 | `a236d38` | Corpo de resposta de vendor limitado; `agy` roda via `BoundedProcess` |
| B10-oauth-keychain (+r2) | 4 | `98e3875` | Refresh atômico single-flight; sem troca de refresh-token obsoleto; Keychain fora do pool |
| B11-app-lows | 7 | `a88c89c` | Dedup de janela Anthropic; fallback do `CachedFetch`; re-login rastreado; notificações podadas |
| B12-cleanup | 16 | `518b03e` | Código morto removido; view de top-models dedupada; diff de Settings fixado; idiomas menores |
| B13-gates-ci | 6 | `96cc790` | Ratchets de fonte compartilhados em CI+validate; coverage floor aceita decimal; checkout fixado; token CI read-only |
| B14-app-followups | 10 | `29fe50c` | Janelas idle/calendário da Analytics; durações saturantes; chaves de notificação estáveis; tooltip stale localizado; fetch travado reiniciado; top-up de config logado |
| B15-core-followups | 13 | `4126da0` | Config ilegível preservado intacto; redirects de DMG com allow-list; leituras limitadas em chunks; drenos de processo abandonáveis; priming de label com leitura única (inclui SEC-MAE-001) |
| B16-final (+r2) | 16 | `72d6b13` | Cooldown de 429 por chegada; título de notificação localizado com retry em entrega falha; idade compartilhada do DiskCache; testes de analytics determinísticos |
| B17-update-sched | 1 | `5f7a4ce` | **UPDATE-SCHED-001** (reportado pelo usuário) — checagem de update uma vez por dia calendário local |
| B18-last-followups (+r2) | 13 | `86804e2` | Tracker de threshold ciente de entrega; percentual arredondado compartilhado; label de quota localizado; back-off de update em repo inválido |
| B19-tail | 4 | `e58b83e` | Cruzamentos pendentes com token; média de analytics arredondada; título com formato 64-bit |
| B20-format-sweep | 1 | `6997e97` | Especificadores de formato inteiro 64-bit em todos os arquivos de strings, com ratchet |
| B21-strings-tail | 3 | `2aef89b` | Uma chave "done" por idioma; literais de formato inline 64-bit; ratchet de formato mais amplo |

Cada linha `docs(audit): B<n> review votes, follow-ups and progress [skip
release]` intercalada nesses commits no `git log` é o Escriba/Maestro
publicando os votos e o progresso daquele lote — não uma correção de
produto.

### Verdict final (pós-remediação)

Depois de 21 lotes adicionais sobre o backlog aberto no round 1, a rodada
fecha em 188 achados: 0 CRITICAL, 3 HIGH (resolvidos no round 1), 11 MEDIUM
(11 resolvidos, incluindo o único item reportado por usuário,
UPDATE-SCHED-001, e os 4 sobreviventes MEDIUM/LOW do painel security-deep),
117 LOW (114 resolvidos, 3 aceitos), 57 INFO (31 resolvidos, 7 aceitos, 16
refutados no round 1, 3 abertos e enfileirados). As 159 correções passaram
todas pelo painel de 3 lentes com voto real (vote-files, 3 votantes); 10
precisaram de uma rodada de `MUDANCAS` antes de aprovar, e zero foram
dispensadas sem o painel (`review.waived` = 0 em todo o arquivo). Os 10
aceites são decisões de risco genuínas — cada um com `type`/`what`/
`consequence`/`reopen_if` — não achados refutados disfarçados nem INFO
cosméticos empurrados para lá sem dono; todos aguardam confirmação do
product owner, conforme registrado. Os 3 abertos restantes são INFO
levantados pelo próprio painel de revisão no último lote (B21), sem
instância atual, corretamente enfileirados em vez de forçados a um
desfecho. A dependência única do projeto (TOMLKit) segue no latest stable,
sem erro de consulta. Não há CRITICAL nem HIGH abertos, e não há aceite
disfarçando um MEDIUM ou HIGH não corrigido: o núcleo está bem blindado
neste fechamento.
