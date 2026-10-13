# Spec review — feature/meta-muse (round 2)

## Fixed in round 2 (verified in current bodies)

- **P-1** (§11 card footer): `MuseSessionScanner.swift:131` now emits zero-dollar `modelBreakdownToday/Last7Days`; scanner + validate asserts pin `hasDisplayData`.
- **P-2** (§8 "sem credencial = estado vazio (§7.3), não erro"): `MetaProvider.swift:65` throws localized `AppError.guidance` (keys in en/pt-BR/es, §12 keychain text included); stale cache is still served via `CachedFetch`, and `CostFooterView` renders below a failed card.
- **P-3** (§4.3 "Desligado: … sem scan."): production init defaults `museEnabled = false` (`CostEstimator.swift:74`), app passes `config.meta.enabled`, refresh gates the seam (`:137`); test asserts zero scanner calls while disabled.
- **P-4** (§11 Settings states): three-way login text + sessions row with the §12 "sem sessões do Muse encontradas" key (`SettingsView.swift:771`).
- **P-5** (§8 "sem redirects"): mint uses `sendBounded(allowRedirect: { _ in false })` + explicit 2xx check (`MetaProvider.swift:74`).
- **P-6** (§10): `.meta: 8` in `vendorColorIndices` (`AnalyticsAggregator.swift:14`).
- **P-7** (§14): 401/403/429/5xx/302 loop, stale-after-success, NaN/∞ percent, validate scanner asserts, rotating-skip test all present.
- **P-8** (§7.1 contracted payload): keychain payload accepts only `access_token` + `dca:` (`MetaCredentialReader.swift:189`); uncontracted shapes are refused by test.

## (c) New violation introduced by the P-4 fix

**P-9 (medium) Settings detection now reads the Keychain secret.** Spec §7.2: "Detetar 'login existe?' (para Ajustes, §4.3) nunca pede o segredo: basta `auth.json` parseável nos termos acima ou presença do item por atributos"; §4.3 requires the detected state "sem ler segredos". `SettingsView.swift:805` calls `detection()`, which ignores the attribute-only `keychainProbe` (`keychainItemPresent`, `kSecReturnAttributes`) and instead calls `keychainRead()` (`MetaCredentialReader.swift:140`) — production-wired to `readKeychain()` with `kSecReturnData = true` (`:216`). Opening Settings (including while Meta is disabled) therefore performs a secret read, merely discarding the payload. It also mislabels any `.failed(OSStatus)` as `.keychainBlocked` (`:142`), where §7.2 reserves blocked for `-25308`/`-25293`. A status-distinguishing attribute query can produce the same three states without the payload.

VERDICT: REJECT
