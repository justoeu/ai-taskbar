import Foundation
import AiTaskbarCore

public enum OpenAIOAuth {
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let scope = "openid profile email"
    public static let refreshBuffer: TimeInterval = 300

    public struct RefreshRequest: Encodable, Sendable {
        public let client_id: String
        public let grant_type: String
        public let refresh_token: String
        public let scope: String
    }

    public struct RefreshResponse: Decodable, Sendable {
        public let access_token: String
        public let refresh_token: String?
        public let id_token: String?
        public let expires_in: Double

        enum CodingKeys: String, CodingKey {
            case access_token, refresh_token, id_token, expires_in
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            access_token = try c.decode(String.self, forKey: .access_token)
            refresh_token = try c.decodeIfPresent(String.self, forKey: .refresh_token)
            id_token = try c.decodeIfPresent(String.self, forKey: .id_token)
            guard let exp = c.flexibleDoubleIfPresent(forKey: .expires_in) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expires_in, in: c,
                    debugDescription: "expected numeric expires_in")
            }
            expires_in = exp
        }
    }

    private static let refresher = OAuthRefresher<RefreshRequest, RefreshResponse>(
        tokenURL: tokenURL,
        extraHeaders: [:],
        timeoutSeconds: 25
    )

    public static func refresh(refreshToken: String,
                               http: HTTPClient) async throws -> RefreshResponse {
        try await refresher.refresh(
            RefreshRequest(client_id: clientID,
                           grant_type: "refresh_token",
                           refresh_token: refreshToken,
                           scope: scope),
            http: http
        )
    }
}
