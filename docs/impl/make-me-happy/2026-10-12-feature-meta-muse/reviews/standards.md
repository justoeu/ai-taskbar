# Standards review — feature/meta-muse (round 1)

No hard documented-standard breach was found, so the axis approves. The
vendor checklist is satisfied: `VendorId` case, `MetaSnapshot`, `[meta]`
config + loader snippet, `CachedFetch` provider, wire types,
`AppEnvironment` wiring, `shortLabel`, fixtures, validate section, and
golden tests are all present. Omitting `api_key_env`/`base_url` and a
`PricingTable` entry matches the CLI-login siblings and is documented in
the diff itself; the fixed `api.meta.ai` host satisfies the allow-list
intent. Hard rules hold: cancellation at entry, after credential
resolution, after the network call, and before encoding for cache;
Keychain reads suppressed with `kSecUseAuthenticationUIFail` and strictly
read-only for the shared CLI credential; `Int(checkedTruncating:)` for
wire doubles; `CostWindow` in the new scanner; disabled by default.
Shotgun Surgery and Repeated Switches are suppressed: the repo checklist
mandates that scattered vendor-add pattern, and the repo overrides the
baseline.

## (a) Documented standards — judgement calls only

- **S-1 (medium):** mint goldens decode synthetic fixtures ("values are
  invented", Fixtures.swift:1269). Testing policy §2 wants a canonical
  fixture freezing the wire contract; here it freezes the author's
  assumed contract. Disclosed in SDD §14 with a real constraint (minting
  spends a login), so not a hard breach — but a verbatim redacted capture
  remains the gap to close.
- **S-2 (low):** `min(100, max(0, percent))` (MetaWireTypes.swift:92)
  duplicates `UsageWindow`'s `UtilizationPercent.sanitized` (AGENTS hard
  rules: sanitized once, 0…1000) and silently narrows the range.
- **S-3 (low):** the test seam `museEstimate = { MuseSessionScanner.estimate() }`
  (CostEstimator.swift:97) defaults to a live scan, unlike its required
  sibling seams, eroding the isolation the seam's own comment promises.

## (b) Baseline smells — judgement calls

- **S-4, Speculative Generality:** the Keychain payload accepts a bare
  string plus three key spellings (MetaCredentialReader.swift:159) for an
  unobserved shape; the `dca:` prefix gate limits the risk.
- **S-5, Duplicated Code:** the memo-hit and fresh-scan merge blocks are
  identical apart from source (MuseSessionScanner.swift:77 vs :92).
- **S-6, Data Clumps:** three aggregate dictionaries plus `drift` travel
  as `inout` parameters through `scan`/`scanLines`
  (MuseSessionScanner.swift:183).

VERDICT: APPROVE
