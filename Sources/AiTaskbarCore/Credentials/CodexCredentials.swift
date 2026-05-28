import Foundation

/// Shape of `~/.codex/auth.json`. The Codex CLI sometimes adds top-level
/// fields we don't recognize (e.g. `last_refresh`) — we round-trip them
/// verbatim via a typed `[String: JSONValue]` instead of `[String: Any]`,
/// so the whole struct is properly `Sendable`.
public struct CodexAuth: Sendable, Equatable {
    public var tokens: CodexTokens
    public var accountId: String?
    /// Any top-level keys we didn't recognize on read. Preserved on write
    /// so the Codex CLI's own state survives a refresh-write.
    public var unknownTopLevel: [String: JSONValue] = [:]

    public init(tokens: CodexTokens, accountId: String? = nil,
                unknownTopLevel: [String: JSONValue] = [:]) {
        self.tokens = tokens
        self.accountId = accountId
        self.unknownTopLevel = unknownTopLevel
    }
}

public struct CodexTokens: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }

    public init(accessToken: String, refreshToken: String, idToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
    }
}
