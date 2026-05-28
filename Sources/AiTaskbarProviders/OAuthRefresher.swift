import Foundation
import AiTaskbarCore

/// Generic OAuth `refresh_token` exchange shared by Anthropic and OpenAI.
/// Each vendor only declares its endpoint, headers, request, and response
/// types — the POST + 2xx check + error-body parsing + decode all live here.
public struct OAuthRefresher<Req: Encodable, Resp: Decodable>: Sendable {
    public let tokenURL: URL
    public let extraHeaders: [String: String]
    public let timeoutSeconds: TimeInterval

    public init(tokenURL: URL,
                extraHeaders: [String: String] = [:],
                timeoutSeconds: TimeInterval = 25) {
        self.tokenURL = tokenURL
        self.extraHeaders = extraHeaders
        self.timeoutSeconds = timeoutSeconds
    }

    public func refresh(_ body: Req, http: HTTPClient) async throws -> Resp {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try SharedCoders.encoder.encode(body)

        let (data, response) = try await http.send(req)
        guard (200..<300).contains(response.statusCode) else {
            let parsed = OAuthErrorBody.parse(data)
                ?? String(data: data.prefix(1024), encoding: .utf8) ?? ""
            throw AppError.credentials(
                "OAuth refresh failed (\(response.statusCode)): \(parsed)")
        }
        do {
            return try SharedCoders.decoder.decode(Resp.self, from: data)
        } catch {
            throw AppError.schema("refresh response decode: \(error)")
        }
    }
}

/// Tolerant parser for the three error-body shapes both Anthropic and
/// OpenAI return on 4xx OAuth failures.
public enum OAuthErrorBody {
    public static func parse(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let obj = json as? [String: Any] {
            if let s = obj["error_description"] as? String { return s }
            if let s = obj["error"] as? String { return s }
            if let nested = obj["error"] as? [String: Any],
               let s = nested["message"] as? String { return s }
        }
        return nil
    }
}
