import Foundation

/// Built-in baseline of TLS SPKI pin hashes for known vendor hosts.
///
/// **Why this exists.** Without a baseline, `PinningDelegate` is Trust-On-
/// First-Use: the first connection to a host seeds the pin. That's vulnerable
/// to anyone who can intercept the first handshake (proxy at install time,
/// or anyone who can `rm` a pin file in `~/Library/Application Support/ai-
/// taskbar/pins/`). A baseline that ships with the binary closes the
/// first-connection window: for hosts listed here, the delegate treats the
/// baseline value as the initial stored pin (no TOFU), so an attacker must
/// defeat TLS itself rather than win a race on first launch.
///
/// **Hash format.** `PinningDelegate.spkiHash(of:)` computes the SHA-256 of
/// `SecKeyCopyExternalRepresentation(publicKey)` — the raw key bytes (e.g.
/// DER-encoded `RSAPublicKey`) WITHOUT the `SubjectPublicKeyInfo` AlgIdentifier
/// wrapper. This is the format `PinningDelegate` itself compares against, so
/// the values below were generated with the same code. They are NOT
/// interchangeable with HPKP / Chromium-style SPKI hashes.
///
/// **Rotation risk.** Pinning is on the public key, not the certificate — so
/// a vendor's routine cert renewal (Let's Encrypt 90-day, etc.) leaves the
/// pin valid as long as they reuse the same key pair. Vendors rarely rotate
/// key pairs; when they do, the pin here needs updating or connections to
/// that host will fail closed. The `auditOnly` config flag lets users ride
/// out a rotation with warnings rather than hard failures.
///
/// **Captured:** 2026-06-18 via `extract_pins.swift` (network trust at extraction
/// time = the user's machine + Apple root store; both are trusted path).
public enum PinBaseline {
    /// `[host-lowercased: base64-sha256-of-spki]`.
    ///
    /// Covers every host the providers + OAuth flows talk to:
    ///   - Anthropic: usage + OAuth token
    ///   - OpenAI: usage + OAuth token
    ///   - OpenRouter: credits + key
    ///   - Z.AI: usage (z.ai global)
    ///   - Kimi: usage (moonshot.ai + .cn fallback)
    ///   - Gemini: models heartbeat
    ///   - DeepSeek: balance
    ///   - Z.AI China endpoint (`open.bigmodel.cn`) is included for users on
    ///     the China region even though the default config uses `api.z.ai`.
    public static let baselineHosts: [String: String] = [
        "api.anthropic.com":                    "1IeW97Q19jhFZCsRxGPOcMOMxiJyasRIcela25Qw2tY=",
        "platform.claude.com":                  "jw5d0cfj7kNCS3Tmz0mzUQyDOZQzxHOq516QxLalF6Q=",
        "chatgpt.com":                          "lvOtdEwiqga+v7ukdbetzO5sMqQcg7hqf47fMJRnqjQ=",
        "auth.openai.com":                      "mIMJoL3PqGYwVpNtiQ+lNHTJ0rsMPIN+Vt+pdLSXIiE=",
        "openrouter.ai":                        "PQ6XQDOhYkFLfv5+zLR/2vY84S5iwSf4mTxiu4wJja0=",
        "api.z.ai":                             "00+eKjEl7/SfoXvKyN2FeYlLrppTWoVwP1AuNOMzOiA=",
        "open.bigmodel.cn":                     "5IFt/3BGsm15zJU313rMdp+95+jI98g47bxZnlJBaU4=",
        "api.moonshot.ai":                      "H0wEcOh/ES0pTJGw26MyKUhbH5NCUz15SmqNPf7Sc80=",
        "api.moonshot.cn":                      "uudumF+9OyzXbIQR0x8DcADr0WGLsHMf+MyT3XHb7uY=",
        "generativelanguage.googleapis.com":    "a5SvX3A73K8gyuUZAoYoPj0QnbN0jj68fErfY/0OPmM=",
        "api.deepseek.com":                     "LGAhpHCTmC6sW60/uo8iqwDJYczUJ4e+NRvv2ewDupk=",
    ]

    /// Returns the baseline pin for `host` (case-insensitive). When non-nil,
    /// `PinningDelegate` treats this as the initial stored hash and skips TOFU
    /// seeding. When nil, the existing TOFU behavior applies.
    public static func pin(for host: String) -> String? {
        baselineHosts[host.lowercased()]
    }
}
