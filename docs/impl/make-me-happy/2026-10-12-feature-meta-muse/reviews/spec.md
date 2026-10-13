# Spec review — feature/meta-muse (round 1)

## (c) Implemented but wrong

**P-1 (high) Card token footer never renders.** Spec §11: "Cartão: reutiliza `VendorSectionView` (plano, janelas com reset, rodapé de custo do scanner)"; §4.1 lists local tokens as a card row. `MuseSessionScanner.swift:121` builds the `CostEstimate` with no `modelBreakdown*` entries, so `hasDisplayData` (`CostEstimate.swift:108`) is always false and `CostFooterView.swift:21` shows nothing. Sibling scanners keep zero-dollar breakdown rows for unpriced models precisely so they stay visible.

**P-2 (high) Missing/blocked login is a noisy error, not an empty state.** Spec §8: "sem credencial = estado vazio (§7.3), não erro"; §7.1: "estado 'sem login' (§4.1), sem erro ruidoso". `MetaProvider.swift:61` throws `AppError.credentials` for `.missing`/`.keychainBlocked`; on a cold cache the card goes `.failed` with red English text. The blocked message also never matches `isKeychainACLBlocked`, and the §12 localized key "acesso ao Keychain indisponível — mostrando só o histórico local" does not exist.

**P-3 (high) Scanner runs while Meta is disabled.** Spec §4.3: "Desligado: sem cartão, sem leituras de Keychain/`auth.json`, sem scan." `CostEstimator.swift:74` always scans Muse sessions and `AiTaskbarApp.swift:67` always constructs/refreshes it, regardless of `config.meta.enabled`.

**P-5 (medium) Mint redirects are followed.** Spec §8: "Host fixo, HTTPS, sem redirects (resposta 3xx = indisponível)." `MetaProvider.swift:71` uses `fetchPayload` → `HTTPClient.send`, documented at `HTTPClient.swift:135` as "URLSession's default redirect handling".

## (a) Missing / partial

**P-4 (medium) Settings state incomplete.** Spec §11: "texto de estado detetado (login presente/ausente; sessões presentes/ausentes; Keychain bloqueado)". `SettingsView.swift:770` shows only a login boolean — no sessions presence, no blocked state (blocked reads "Detected"); §12's "sem sessões do Muse encontradas" key is also absent.

**P-6 (low)** Spec §10: "entrada `.meta` em `vendorColorIndices`". `AnalyticsAggregator.swift:5` has no `.meta` entry (fallback index can collide).

**P-7 (low) Required tests absent.** Spec §14: "401/403/429/5xx; stale em falha"; golden case "`used_percent` não-finito"; validate section "(decode rápido + scanner)"; §4.2 rotating-skip "confirmar por teste na task de UI". `MetaProviderTests.swift:136` covers only 401; the validate section has no scanner assert.

## (b) Not asked for

**P-8 (low)** Spec §7.1: Keychain "o payload é JSON — extrair só o access token". `MetaCredentialReader.swift:159` additionally accepts a bare non-JSON string and guessed `accessToken`/`token` keys — uncontracted shapes, untested against the real CLI item.

VERDICT: REJECT
