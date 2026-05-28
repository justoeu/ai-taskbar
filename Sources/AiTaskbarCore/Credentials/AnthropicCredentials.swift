import Foundation

/// File-format wrapper: `{ "claudeAiOauth": { ... } }`.
public struct AnthropicCredentialsFile: Codable, Sendable {
    public var claudeAiOauth: AnthropicCredentials
}

public struct AnthropicCredentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Milliseconds since epoch. Accepts Int or Float on decode.
    public var expiresAtMs: Int64
    public var subscriptionType: String?
    public var rateLimitTier: String?

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
}
