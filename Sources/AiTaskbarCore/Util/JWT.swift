import Foundation

/// Minimal helper for unauthenticated JWT payload extraction. We never verify
/// the signature here — these tokens come from CLI credential files we trust
/// for the purpose of reading their plan tier / expiry claims.
public enum JWT {
    public static func decodePayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payload = base64UrlDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return json
    }

    /// Returns the `exp` claim (seconds since epoch) as a Date if present.
    public static func expiry(_ token: String) -> Date? {
        guard let payload = decodePayload(token) else { return nil }
        if let exp = payload["exp"] as? Double {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = payload["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        return nil
    }

    /// Looks up a claim by exact key — used for vendor-specific claims like
    /// `"https://api.openai.com/auth.chatgpt_plan_type"`.
    public static func claim<T>(_ token: String, key: String, as: T.Type) -> T? {
        decodePayload(token)?[key] as? T
    }

    public static func base64UrlDecode(_ input: String) -> Data? {
        var s = input.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        s.append(String(repeating: "=", count: pad))
        return Data(base64Encoded: s)
    }
}
