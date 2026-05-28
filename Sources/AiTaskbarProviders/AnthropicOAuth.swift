import Foundation
import AiTaskbarCore

/// Constants and request shapes for the Anthropic OAuth refresh flow used by
/// the official Claude CLI. The client_id below is the **public** identifier
/// the CLI ships with — it is not a secret.
public enum AnthropicOAuth {
    public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let betaHeader = "oauth-2025-04-20"
    public static let userAgent = "claude-cli/1.0"
    public static let refreshBuffer: TimeInterval = 300

    public struct RefreshRequest: Encodable, Sendable {
        public let grant_type: String
        public let client_id: String
        public let refresh_token: String
    }

    public struct RefreshResponse: Decodable, Sendable {
        public let access_token: String
        public let refresh_token: String?
        public let expires_in: Double

        enum CodingKeys: String, CodingKey {
            case access_token, refresh_token, expires_in
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            access_token = try c.decode(String.self, forKey: .access_token)
            refresh_token = try c.decodeIfPresent(String.self, forKey: .refresh_token)
            guard let exp = c.flexibleDoubleIfPresent(forKey: .expires_in) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expires_in, in: c,
                    debugDescription: "expected numeric expires_in")
            }
            expires_in = exp
        }
    }

    /// Reuses the shared OAuth refresh skeleton.
    private static let refresher = OAuthRefresher<RefreshRequest, RefreshResponse>(
        tokenURL: tokenURL,
        extraHeaders: [
            "anthropic-beta": betaHeader,
            "User-Agent":     userAgent,
        ],
        timeoutSeconds: 25
    )

    /// Backwards-compat shim — callers in the codebase still reach for
    /// `AnthropicOAuth.parseErrorBody`. Delegates to the shared parser.
    public static func parseErrorBody(_ data: Data) -> String? {
        OAuthErrorBody.parse(data)
    }

    public static func refresh(refreshToken: String,
                               http: HTTPClient) async throws -> RefreshResponse {
        try await refresher.refresh(
            RefreshRequest(grant_type: "refresh_token",
                           client_id: clientID,
                           refresh_token: refreshToken),
            http: http
        )
    }
}
