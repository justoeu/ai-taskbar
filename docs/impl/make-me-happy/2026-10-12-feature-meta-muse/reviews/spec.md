# Spec review — feature/meta-muse (round 3)

## Fixed in round 3 (verified in current bodies)

- **P-9** (§7.2 "Detetar 'login existe?' … nunca pede o segredo"): production
  `init(config:)` injects `keychainProbe: { Self.probeKeychain() }`
  (`MetaCredentialReader.swift:108`); `detection()` (`:161`) switches on the
  probe with every case returning, so `keychainRead()` is unreachable on the
  production path. `probeKeychain()` (`:273`) sets only
  `kSecReturnAttributes` (never `kSecReturnData`), inside
  `withPromptsSuppressed` + `kSecUseAuthenticationUIFail`. Settings calls
  `MetaCredentialReader(config:).detection()` (`SettingsView.swift:805`) — no
  secret is requested when the pane opens, disabled or not.
- Blocked is again reserved for the ACL statuses: the probe maps
  `isACLBlockedStatus` (`errSecInteractionNotAllowed` /
  `errSecAuthFailed`, `KeychainCredentialReader.swift:325`) to `.blocked`;
  any other status becomes `.failed` → `.unavailable` (`:168`). The new test
  `detection_uses_probe_not_read` pins probe precedence (probe `.blocked`
  beats a readable token) and that only `resolve()` reads the payload.

P-1..P-8 remain fixed as verified in round 2; the P-9 diff introduces no new
spec deviation (the `.unavailable` state reuses the generic "Keychain access
unavailable" string, which §11's three-state Settings text does not forbid).

VERDICT: APPROVE
