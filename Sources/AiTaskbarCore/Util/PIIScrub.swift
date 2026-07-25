import Foundation

/// Removes identifying fields from vendor payloads before they touch disk.
///
/// Extracted from `OpenAIProvider.stripPII`, which scrubbed only the SUCCESS
/// payload. Error bodies took a different path — `CachedFetch` persists them
/// verbatim into `.last_error` — so an HTTP 4xx that echoed the account back
/// wrote exactly the fields the success path is careful to strip. Sharing one
/// scrubber means the two paths cannot drift again.
public enum PIIScrub {
    /// Keys removed at every depth. These are the identifiers vendors echo
    /// back; none of them is needed for a usage snapshot or for diagnosing a
    /// failed fetch.
    public static let sensitiveKeys: Set<String> = [
        "user_id", "account_id", "email", "user", "account",
        "organization", "organization_id", "org_id", "owner",
    ]

    /// Recursively drops `sensitiveKeys` from every object in the tree.
    /// Arrays and scalars pass through untouched.
    public static func scrub(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let obj):
            var cleaned: [String: JSONValue] = [:]
            cleaned.reserveCapacity(obj.count)
            for (k, v) in obj where !sensitiveKeys.contains(k) {
                cleaned[k] = scrub(v)
            }
            return .object(cleaned)
        case .array(let arr):
            return .array(arr.map(scrub))
        default:
            return value
        }
    }

    /// Scrubs JSON bytes, returning the original when the payload isn't a JSON
    /// object (nothing to strip, and rewriting would churn byte-stable data).
    public static func scrub(bytes raw: Data) -> Data {
        guard let value = try? SharedCoders.decoder.decode(JSONValue.self, from: raw),
              case .object = value,
              let out = try? SharedCoders.encoder.encode(scrub(value))
        else { return raw }
        return out
    }

    /// Scrubs a diagnostic string destined for disk or a log.
    ///
    /// Error bodies are not always JSON — a proxy or gateway can return HTML,
    /// a stack trace, or a bare sentence — so JSON scrubbing alone would let
    /// an address through in the non-JSON case. Emails are redacted textually
    /// as a backstop, and the result is capped: a diagnostic only needs enough
    /// to identify the failure, and an unbounded body is its own problem when
    /// it lands in a file the app rewrites on every failed refresh.
    public static func scrub(diagnostic text: String, maxLength: Int = 2048) -> String {
        var out = text
        if let data = text.data(using: .utf8) {
            let scrubbed = scrub(bytes: data)
            if scrubbed.count != data.count, let s = String(data: scrubbed, encoding: .utf8) {
                out = s
            }
        }
        out = redactEmails(in: out)
        if out.count > maxLength {
            out = String(out.prefix(maxLength)) + "… (truncated)"
        }
        return out
    }

    private static let emailPattern = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        options: [.caseInsensitive])

    static func redactEmails(in text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return emailPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: "<redacted-email>")
    }
}
