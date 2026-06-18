import Foundation

/// Minimal helper for unauthenticated JWT payload extraction. We never verify
/// the signature here — these tokens come from CLI credential files we trust
/// for the purpose of reading their plan tier / expiry claims.
///
/// Decodes into `JSONValue` (not `[String: Any]`) so the result is `Sendable`
/// and can safely cross actor boundaries per the AGENTS.md hard rule.
public enum JWT {
    public static func decodePayload(_ token: String) -> JSONValue? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payload = base64UrlDecode(String(parts[1]))
        else { return nil }
        return try? SharedCoders.decoder.decode(JSONValue.self, from: payload)
    }

    /// Returns the `exp` claim (seconds since epoch) as a Date if present.
    public static func expiry(_ token: String) -> Date? {
        guard let payload = decodePayload(token),
              case .object(let obj) = payload
        else { return nil }
        switch obj["exp"] ?? .null {
        case .double(let d): return Date(timeIntervalSince1970: d)
        case .int(let i):    return Date(timeIntervalSince1970: TimeInterval(i))
        default:             return nil
        }
    }

    /// Looks up a claim by exact key — used for vendor-specific claims like
    /// `"https://api.openai.com/auth.chatgpt_plan_type"`. Type-narrows against
    /// the `JSONValue` sum type so callers stay statically typed.
    public static func claim<T>(_ token: String, key: String, as: T.Type) -> T? {
        guard let payload = decodePayload(token),
              case .object(let obj) = payload,
              let v = obj[key]
        else { return nil }
        return Self.cast(v, to: T.self)
    }

    /// Statically-typed extraction from a `JSONValue`. Supports the scalar
    /// shapes that ever appear in JWT payloads we read.
    @inline(__always)
    private static func cast<T>(_ v: JSONValue, to: T.Type) -> T? {
        switch (v, T.self) {
        case (.string(let s), is String.Type):  return s as? T
        case (.int(let i),    is String.Type):  return String(i) as? T
        case (.int(let i),    is Int.Type):     return Int(truncatingIfNeeded: i) as? T
        case (.int(let i),    is Int64.Type):   return i as? T
        case (.int(let i),    is Double.Type):  return Double(i) as? T
        case (.double(let d), is Double.Type):  return d as? T
        case (.double(let d), is Int.Type):     return Int(d) as? T
        case (.double(let d), is Int64.Type):   return Int64(d) as? T
        case (.bool(let b),   is Bool.Type):    return b as? T
        default:                                 return nil
        }
    }

    public static func base64UrlDecode(_ input: String) -> Data? {
        var s = input.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        s.append(String(repeating: "=", count: pad))
        return Data(base64Encoded: s)
    }
}
