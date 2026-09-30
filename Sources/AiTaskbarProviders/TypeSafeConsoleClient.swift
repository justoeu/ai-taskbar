import Foundation
import AiTaskbarCore

/// Why a console read failed. Deliberately carries no body: console pages hold
/// the account's e-mail and billing details.
public enum TypeSafeConsoleError: Error, Equatable {
    /// 401/403, any redirect, or the login screen: sign in again.
    case sessionExpired
    /// 408/429/5xx, a Cloudflare interstitial, transport or format trouble.
    case unavailable(String)
}

/// Read-only client for `console.typesafe.ai` (docs/SDD-typesafe-jev.md §16.5).
///
/// - Talks to that one host only; chunk URLs are filtered to it and every
///   redirect is refused (a redirect reads as an expired session).
/// - Sends only the login-cookie header it is given and the app's honest
///   User-Agent, through the shared cookie-less ephemeral session.
/// - Makes the same GETs and the same read-only server action the console
///   pages make to render themselves; nothing that changes the account.
public final class TypeSafeConsoleClient: @unchecked Sendable {
    public static let actionIDTTL: TimeInterval = 12 * 60 * 60
    /// After a failed discovery, don't re-download the chunks for this long:
    /// a console deploy that moved the action would otherwise cost the page
    /// plus up to 60 chunks on every refresh.
    public static let discoveryFailureBackoff: TimeInterval = 60 * 60
    /// Total chunk bytes one discovery may download, and its overall budget.
    static let discoveryMaxBytes = 16 * 1024 * 1024
    static let discoveryDeadline: TimeInterval = 30
    static let pageBytes = 4 * 1024 * 1024
    static let chunkBytes = 4 * 1024 * 1024
    static let resultBytes = 1024 * 1024

    private let http: HTTPClient
    private let userAgent: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cachedAction: (id: String, at: Date)?
    private var discoveryFailedAt: Date?

    public init(http: HTTPClient,
                userAgent: String = TypeSafeConsoleClient.defaultUserAgent,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.userAgent = userAgent
        self.now = now
    }

    public static var defaultUserAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "ai-taskbar/\(version) (macOS; +https://github.com/justoeu/ai-taskbar)"
    }

    static let billingURL = URL(string: TypeSafeConsoleParsing.origin + "/settings/billing")!
    static func usageURL(_ granularity: String) -> URL {
        URL(string: TypeSafeConsoleParsing.origin + "/api/usage?granularity=\(granularity)")!
    }

    // MARK: billing

    public func fetchBilling(cookie: String) async throws -> TypeSafeBilling {
        var id = try await actionID(cookie: cookie, forceDiscovery: false)
        for attempt in 0..<2 {
            var req = request(Self.billingURL, cookie: cookie, accept: "text/x-component", timeout: 6)
            req.httpMethod = "POST"
            req.setValue(TypeSafeConsoleParsing.origin, forHTTPHeaderField: "Origin")
            req.setValue(id, forHTTPHeaderField: "Next-Action")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("[]".utf8)
            let (data, resp) = try await send(req, maxBytes: Self.resultBytes)
            // A deploy renamed the action: rediscover once.
            if resp.statusCode == 404, resp.value(forHTTPHeaderField: "x-nextjs-action-not-found") == "1", attempt == 0 {
                clearActionID()
                id = try await actionID(cookie: cookie, forceDiscovery: true)
                continue
            }
            let body = String(decoding: data, as: UTF8.self)
            try classify(resp, body: body)
            do {
                return try TypeSafeConsoleParsing.billing(fromRSC: body)
            } catch {
                throw TypeSafeConsoleError.unavailable("billing format changed")
            }
        }
        throw TypeSafeConsoleError.unavailable("billing action not found")
    }

    func actionID(cookie: String, forceDiscovery: Bool) async throws -> String {
        if !forceDiscovery, let cached = cachedActionID() { return cached }
        if let failed = discoveryFailure(), now().timeIntervalSince(failed) < Self.discoveryFailureBackoff {
            throw TypeSafeConsoleError.unavailable("billing action id not found (backing off)")
        }
        let (pageData, pageResp) = try await send(
            request(Self.billingURL, cookie: cookie, accept: "text/html", timeout: 6), maxBytes: Self.pageBytes)
        let html = String(decoding: pageData, as: UTF8.self)
        try classify(pageResp, body: html)
        if TypeSafeConsoleParsing.isLoginLanding(html) { throw TypeSafeConsoleError.sessionExpired }
        let started = Date()
        var downloaded = 0
        for url in TypeSafeConsoleParsing.chunkURLs(inPage: html) {
            try Task.checkCancellation()
            guard downloaded < Self.discoveryMaxBytes,
                  Date().timeIntervalSince(started) < Self.discoveryDeadline else { break }
            // Chunks are public static assets: no cookie.
            var req = URLRequest(url: url, timeoutInterval: 4)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let data: Data
            do {
                let (body, resp) = try await send(req, maxBytes: Self.chunkBytes)
                guard resp.statusCode == 200 else { continue }
                data = body
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue   // one missing chunk is not fatal; the next may hold the id
            }
            downloaded += data.count
            if let id = TypeSafeConsoleParsing.actionID(inChunk: String(decoding: data, as: UTF8.self)) {
                storeActionID(id)
                return id
            }
        }
        recordDiscoveryFailure()
        throw TypeSafeConsoleError.unavailable("billing action id not found")
    }

    // MARK: usage

    public func fetchUsage(cookie: String, calendar: Calendar = .current) async throws -> TypeSafeUsage {
        async let hour = usageBuckets("hour", cookie: cookie)
        async let day = usageBuckets("day", cookie: cookie)
        return TypeSafeUsageMath.aggregate(hour: try await hour, day: try await day, now: now(), calendar: calendar)
    }

    private func usageBuckets(_ granularity: String, cookie: String) async throws -> [TypeSafeUsageBucket] {
        let (data, resp) = try await send(
            request(Self.usageURL(granularity), cookie: cookie, accept: "application/json", timeout: 6),
            maxBytes: Self.resultBytes)
        try classify(resp, body: String(decoding: data.prefix(4096), as: UTF8.self))
        do {
            return try SharedCoders.decoder.decode(TypeSafeUsageResponse.self, from: data).buckets
        } catch {
            // An HTML login page instead of JSON means the session is gone.
            if TypeSafeConsoleParsing.isLoginLanding(String(decoding: data, as: UTF8.self)) {
                throw TypeSafeConsoleError.sessionExpired
            }
            throw TypeSafeConsoleError.unavailable("usage format changed")
        }
    }

    // MARK: plumbing

    private func request(_ url: URL, cookie: String, accept: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    private func send(_ req: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard req.url?.host == TypeSafeConsoleParsing.host, req.url?.scheme == "https" else {
            throw TypeSafeConsoleError.unavailable("refused non-console host")
        }
        do {
            return try await http.sendBounded(req, maximumResponseBytes: maxBytes, allowRedirect: { _ in false })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TypeSafeConsoleError.unavailable("transport")
        }
    }

    /// Maps a response status onto the two failure kinds (SDD §16.5).
    func classify(_ resp: HTTPURLResponse, body: String) throws {
        let status = resp.statusCode
        if TypeSafeConsoleParsing.isCloudflareChallenge(status: status, headers: resp.allHeaderFields, body: body) {
            throw TypeSafeConsoleError.unavailable("cloudflare challenge")
        }
        switch status {
        case 200..<300: return
        case 300..<400, 401, 403: throw TypeSafeConsoleError.sessionExpired
        default: throw TypeSafeConsoleError.unavailable("HTTP \(status)")
        }
    }

    private func cachedActionID() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let c = cachedAction, now().timeIntervalSince(c.at) < Self.actionIDTTL else { return nil }
        return c.id
    }

    private func storeActionID(_ id: String) {
        let at = now()
        lock.lock(); cachedAction = (id, at); discoveryFailedAt = nil; lock.unlock()
    }

    private func discoveryFailure() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return discoveryFailedAt
    }

    private func recordDiscoveryFailure() {
        let at = now()
        lock.lock(); discoveryFailedAt = at; lock.unlock()
    }

    private func clearActionID() {
        lock.lock(); cachedAction = nil; lock.unlock()
    }
}
