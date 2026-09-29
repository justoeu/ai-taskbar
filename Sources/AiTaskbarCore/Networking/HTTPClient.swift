import Foundation

public final class HTTPClient: @unchecked Sendable {
    private let session: URLSession
    public let defaultTimeout: TimeInterval

    /// Process-wide ephemeral session. Differences from `URLSession.shared`:
    ///   - No URLCache → drops ~4 MB RAM + 20 MB on-disk that we never use
    ///     (our `DiskCache` is the source of truth).
    ///   - No persistent cookies / credential storage → privacy win.
    ///   - Capped connections per host (4) — vendor APIs don't need more.
    /// One instance reused across providers so connection pooling still works.
    private static let sharedEphemeral: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 30
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        return URLSession(configuration: cfg)
    }()

    public init(session: URLSession? = nil, defaultTimeout: TimeInterval = 10) {
        self.session = session ?? Self.sharedEphemeral
        self.defaultTimeout = defaultTimeout
    }

    /// Build a client whose `URLSession` is bound to a TLS pinning delegate.
    /// Non-pinned hosts fall through to system trust; pinned hosts use TOFU
    /// SPKI hashes stored on disk.
    ///
    /// Empty `pinnedHosts` returns a plain ephemeral client (no pinning).
    /// Non-empty list **fails closed** if `PinStore` cannot be created —
    /// never silently returns an unpinned client while the caller believes
    /// pinning is active (SEC-SEN-003).
    public static func pinned(pinnedHosts: [String],
                              auditOnly: Bool = false) throws -> HTTPClient {
        guard !pinnedHosts.isEmpty else {
            return HTTPClient()
        }
        let store: PinStore
        do {
            store = try PinStore.defaultStore()
        } catch {
            throw AppError.io("PinStore unavailable while pin_hosts is set: \(error)")
        }
        let delegate = PinningDelegate(pinnedHosts: pinnedHosts,
                                       store: store,
                                       auditOnly: auditOnly)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 30
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        return HTTPClient(session: session)
    }

    /// Download a remote resource to a temp file via this client's session
    /// (so pinning / ephemeral policy apply). Caller moves/copies the file.
    public func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        try Task.checkCancellation()
        var req = request
        if req.timeoutInterval <= 0 || req.timeoutInterval > 3600 {
            req.timeoutInterval = max(defaultTimeout, 120)
        }
        let tmp: URL
        let response: URLResponse
        do {
            (tmp, response) = try await session.download(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlErr as URLError {
            if urlErr.code == .cancelled { throw CancellationError() }
            throw AppError.transport("URLError \(urlErr.code.rawValue): \(urlErr.localizedDescription)")
        } catch {
            throw AppError.transport(error.localizedDescription)
        }
        // From here the temp file is ours: URLSession does not delete it,
        // so every rejection below must (LEAK-FAN-004).
        do {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw AppError.transport("non-HTTP download response")
            }
            return (tmp, http)
        } catch {
            try? FileManager.default.removeItem(at: tmp) // best-effort cleanup
            throw error
        }
    }

    /// For tests — produce a client backed by URLSession with a custom
    /// URLProtocol stack (e.g. StubURLProtocol).
    public static func stubbed(protocols: [AnyClass]) -> HTTPClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = protocols + (cfg.protocolClasses ?? [])
        return HTTPClient(session: URLSession(configuration: cfg))
    }

    /// Test helper — exposes the active session's configuration so the
    /// validate suite can confirm ephemeral semantics.
    public var sessionConfiguration: URLSessionConfiguration { session.configuration }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        var req = request
        if req.timeoutInterval <= 0 || req.timeoutInterval > 3600 {
            req.timeoutInterval = defaultTimeout
        }
        do {
            let (data, response) = try await session.data(for: req)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw AppError.transport("non-HTTP response")
            }
            return (data, http)
        } catch let appErr as AppError {
            throw appErr
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlErr as URLError {
            // URLSession surfaces task cancellation as URLError.cancelled.
            // Re-throw as Swift CancellationError so callers can handle it
            // uniformly.
            if urlErr.code == .cancelled { throw CancellationError() }
            throw AppError.transport("URLError \(urlErr.code.rawValue): \(urlErr.localizedDescription)")
        } catch {
            throw AppError.transport(error.localizedDescription)
        }
    }

    /// Streams a bounded response while allowing redirects only inside the
    /// request's original HTTPS origin, or, when `allowRedirect` is given,
    /// only to HTTPS targets it accepts. The redirect decision happens before
    /// URLSession follows the Location header.
    public func sendBounded(
        _ request: URLRequest,
        maximumResponseBytes: Int,
        allowRedirect: (@Sendable (URL) -> Bool)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard maximumResponseBytes >= 0, let origin = request.url else {
            throw AppError.transport("invalid bounded HTTP request")
        }
        var req = request
        if req.timeoutInterval <= 0 || req.timeoutInterval > 3600 {
            req.timeoutInterval = defaultTimeout
        }
        let redirectDelegate = BoundedRedirectDelegate(origin: origin, allow: allowRedirect)
        do {
            let (bytes, response) = try await session.bytes(
                for: req,
                delegate: redirectDelegate
            )
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw AppError.transport("non-HTTP response")
            }
            if http.expectedContentLength > Int64(maximumResponseBytes) {
                throw AppError.transport(
                    "HTTP response exceeds \(maximumResponseBytes) bytes"
                )
            }
            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(min(
                    maximumResponseBytes,
                    Int(http.expectedContentLength)
                ))
            }
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumResponseBytes else {
                    throw AppError.transport(
                        "HTTP response exceeds \(maximumResponseBytes) bytes"
                    )
                }
                data.append(byte)
            }
            return (data, http)
        } catch let appErr as AppError {
            throw appErr
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlErr as URLError {
            if urlErr.code == .cancelled { throw CancellationError() }
            throw AppError.transport(
                "URLError \(urlErr.code.rawValue): \(urlErr.localizedDescription)"
            )
        } catch {
            throw AppError.transport(error.localizedDescription)
        }
    }

    /// Convenience: send + decode JSON, throwing `.http` on non-2xx and
    /// `.schema` on decode failure. Uses the shared decoder unless caller
    /// supplies one — avoids per-call decoder allocations on hot paths.
    public func sendDecoding<T: Decodable>(
        _ request: URLRequest,
        as: T.Type,
        decoder: JSONDecoder = SharedCoders.decoder
    ) async throws -> T {
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data.prefix(1024), encoding: .utf8) ?? "<binary \(data.count) bytes>"
            throw AppError.http(status: response.statusCode, body: body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw AppError.schema("decode \(T.self): \(error). body=\(preview)")
        }
    }
}

/// Redirect policy for bounded fetches: same-origin by default, the `allow` predicate when given, and always HTTPS without userinfo.
private final class BoundedRedirectDelegate:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
    private let scheme: String?
    private let host: String?
    private let port: Int?
    private let allow: (@Sendable (URL) -> Bool)?

    init(origin: URL, allow: (@Sendable (URL) -> Bool)?) {
        scheme = origin.scheme?.lowercased()
        host = origin.host?.lowercased()
        port = origin.port
        self.allow = allow
    }

    private func sameOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
            && url.host?.lowercased() == host
            && url.port == port
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              scheme == "https",
              url.scheme?.lowercased() == "https",
              allow?(url) ?? sameOrigin(url),
              url.user == nil,
              url.password == nil
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
