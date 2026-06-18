import Foundation

/// File-format wrapper: `{ "claudeAiOauth": { ... } }`.
public struct AnthropicCredentialsFile: Codable, Sendable {
    public var claudeAiOauth: AnthropicCredentials
}

public struct AnthropicCredentials: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    /// Milliseconds since epoch. Accepts Int or Float on decode.
    public let expiresAtMs: Int64
    public let subscriptionType: String?
    public let rateLimitTier: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAtMs = "expiresAt"
        case subscriptionType
        case rateLimitTier
    }

    public init(accessToken: String,
                refreshToken: String,
                expiresAtMs: Int64,
                subscriptionType: String? = nil,
                rateLimitTier: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAtMs = expiresAtMs
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = try c.decode(String.self, forKey: .accessToken)
        self.refreshToken = try c.decode(String.self, forKey: .refreshToken)
        // expiresAt arrives as Int or Float depending on client.
        if let i = try? c.decode(Int64.self, forKey: .expiresAtMs) {
            self.expiresAtMs = i
        } else {
            let d = try c.decode(Double.self, forKey: .expiresAtMs)
            self.expiresAtMs = Int64(d)
        }
        self.subscriptionType = try c.decodeIfPresent(String.self, forKey: .subscriptionType)
        self.rateLimitTier = try c.decodeIfPresent(String.self, forKey: .rateLimitTier)
    }

    public var expiresAt: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1000)
    }

    public func isExpired(buffer: TimeInterval = 300, now: Date = .init()) -> Bool {
        expiresAt < now.addingTimeInterval(buffer)
    }

    /// Returns a copy with the OAuth fields rotated. Used after a successful
    /// `refresh_token` exchange — replacing in-place `var` mutation keeps the
    /// credential value type immutable (safer across the actor boundary it
    /// crosses on its way back to the keychain reader).
    ///
    /// `refreshToken` falls back to the existing token when the OAuth response
    /// didn't include a new one (some IdPs omit it when the rotation policy
    /// re-uses the same token).
    public func rotated(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date
    ) -> AnthropicCredentials {
        AnthropicCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken ?? self.refreshToken,
            expiresAtMs: Int64(expiresAt.timeIntervalSince1970 * 1000),
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier
        )
    }
}
