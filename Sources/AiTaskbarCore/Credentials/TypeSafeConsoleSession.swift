import Foundation

/// The TypeSafe console session (phase 2, docs/SDD-typesafe-jev.md §16.4):
/// the three login cookies as a `Cookie` header value plus their expiry.
/// Only these cookies ever leave the login window — never the Cloudflare
/// clearance or analytics cookies.
public struct TypeSafeConsoleSession: Sendable, Equatable {
    /// The only cookies copied out of the login window, in this fixed order.
    public static let loginCookieNames = ["session", "session_id", "organization_id"]
    /// Warn this long before the session expires.
    public static let expiryWarning: TimeInterval = 2 * 24 * 60 * 60

    public let cookieHeader: String
    public let expiresAt: Date?

    public init(cookieHeader: String, expiresAt: Date?) {
        self.cookieHeader = cookieHeader
        self.expiresAt = expiresAt
    }

    /// From the persisted config fields; nil when not connected or when the
    /// stored header is not exactly the three login cookies (a hand-edited
    /// file cannot smuggle another header or cookie). An expiry of 0 or less
    /// is "none": sign-out and cookies without an expiry both write 0.
    public init?(config: TypeSafeConfig) {
        guard let header = config.consoleSession, Self.isValidHeader(header) else { return nil }
        let expiry = config.consoleSessionExpiresAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        self.init(cookieHeader: header, expiresAt: expiry)
    }

    /// `session=…; session_id=…; organization_id=…`, header-safe values.
    static func isValidHeader(_ header: String) -> Bool {
        let pairs = header.components(separatedBy: "; ")
        guard pairs.count == loginCookieNames.count else { return false }
        for (pair, name) in zip(pairs, loginCookieNames) {
            guard pair.hasPrefix(name + "=") else { return false }
            let value = String(pair.dropFirst(name.count + 1))
            guard !value.isEmpty, isHeaderSafe(value) else { return false }
        }
        return true
    }

    /// Builds the session from captured cookies, keeping only the login ones.
    /// Nil unless all three are present and non-empty. The expiry is the
    /// earliest of theirs (a session cookie without one does not shorten it).
    public static func capture(_ cookies: [(name: String, value: String, expiresAt: Date?)]) -> TypeSafeConsoleSession? {
        var byName: [String: String] = [:]
        var expiry: Date?
        for c in cookies where loginCookieNames.contains(c.name) && !c.value.isEmpty
            && Self.isHeaderSafe(c.value) {
            byName[c.name] = c.value
            if let e = c.expiresAt { expiry = min(expiry ?? e, e) }
        }
        guard byName.count == loginCookieNames.count else { return nil }
        let header = loginCookieNames.map { "\($0)=\(byName[$0]!)" }.joined(separator: "; ")
        return TypeSafeConsoleSession(cookieHeader: header, expiresAt: expiry)
    }

    public func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    public func isExpiringSoon(now: Date) -> Bool {
        expiresAt.map { Self.isExpiringSoon(expiresAt: $0, now: now) } ?? false
    }

    /// Inside the warning window but not yet expired.
    public static func isExpiringSoon(expiresAt: Date, now: Date) -> Bool {
        now < expiresAt && expiresAt.timeIntervalSince(now) <= expiryWarning
    }

    /// A cookie value that would split or inject a header is refused.
    /// Printable ASCII only, no separators: control characters, tabs and
    /// non-ASCII are refused along with `;`, `,` and spaces.
    static func isHeaderSafe(_ v: String) -> Bool {
        v.unicodeScalars.allSatisfy { s in
            s.value > 0x20 && s.value < 0x7F && s != ";" && s != ","
        }
    }
}

/// Process-wide holder of the current console session, so an in-app login
/// takes effect on the next fetch without a relaunch. Seeded from config at
/// launch; the login window updates it after persisting.
public final class TypeSafeSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var session: TypeSafeConsoleSession?

    public init(_ session: TypeSafeConsoleSession? = nil) { self.session = session }

    public var current: TypeSafeConsoleSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    public func set(_ new: TypeSafeConsoleSession?) {
        lock.lock(); session = new; lock.unlock()
    }
}
