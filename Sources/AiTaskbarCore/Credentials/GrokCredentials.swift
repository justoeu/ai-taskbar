import Foundation

/// Shape of an entry in `~/.grok/auth.json`.
public struct GrokAuthEntry: Sendable, Equatable, Codable {
    public var key: String
    public var authMode: String?
    public var userId: String?
    public var email: String?
    public var teamId: String?
    public var refreshToken: String?
    public var expiresAt: String?
    public var oidcIssuer: String?
    public var oidcClientId: String?

    enum CodingKeys: String, CodingKey {
        case key
        case authMode = "auth_mode"
        case userId = "user_id"
        case email
        case teamId = "team_id"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case oidcIssuer = "oidc_issuer"
        case oidcClientId = "oidc_client_id"
    }

    public init(key: String,
                authMode: String? = nil,
                userId: String? = nil,
                email: String? = nil,
                teamId: String? = nil,
                refreshToken: String? = nil,
                expiresAt: String? = nil,
                oidcIssuer: String? = nil,
                oidcClientId: String? = nil) {
        self.key = key
        self.authMode = authMode
        self.userId = userId
        self.email = email
        self.teamId = teamId
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.oidcIssuer = oidcIssuer
        self.oidcClientId = oidcClientId
    }

    /// Whether this credential has expired according to its ISO8601 `expires_at` timestamp.
    public var isExpired: Bool {
        guard let expStr = expiresAt, let date = ISO8601Parsing.parse(expStr) else {
            return false
        }
        return date < Date()
    }
}

/// Reader for `~/.grok/auth.json`.
public struct GrokAuthReader: Sendable {
    public let path: URL

    public init(path: URL = Paths.defaultGrokAuth()) {
        self.path = path
    }

    public func read() throws -> GrokAuthEntry {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw AppError.credentials("Grok auth file not found at \(path.path)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw AppError.io("Failed to read Grok auth file at \(path.path): \(error)")
        }

        // auth.json maps scope -> GrokAuthEntry (e.g. "https://auth.x.ai::uuid" -> entry)
        do {
            let entries = try JSONDecoder().decode([String: GrokAuthEntry].self, from: data)
            if let entry = entries.values.first(where: { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return entry
            }
        } catch {
            // Also tolerate single GrokAuthEntry directly if format ever varies
            if let entry = try? JSONDecoder().decode(GrokAuthEntry.self, from: data),
               !entry.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return entry
            }
            throw AppError.schema("Failed to decode Grok auth file: \(error)")
        }

        throw AppError.credentials("No valid credentials found in Grok auth file at \(path.path)")
    }
}

/// Reader for local Grok cache files (e.g. `~/.grok/settings_cache.json`).
public enum GrokLocalCache {
    public static func readSubscriptionTierDisplay(at path: URL = Paths.defaultGrokSettingsCache()) -> String? {
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case .string(let payloadStr)? = json["payload"],
              let payloadData = payloadStr.data(using: .utf8),
              let payloadJson = try? JSONDecoder().decode([String: JSONValue].self, from: payloadData),
              case .object(let settings)? = payloadJson["settings"],
              case .string(let tier)? = settings["subscription_tier_display"],
              !tier.isEmpty
        else { return nil }
        return tier
    }
}
