import Foundation
import os

public final class HTTPClient: @unchecked Sendable {
    private let session: URLSession
    public let defaultTimeout: TimeInterval

    /// Ceiling on a `send` / `sendDecoding` body (8 MiB). The largest real
    /// usage payload we have a fixture for is ~4 KB, so this is ~2000x
    /// headroom while still refusing a runaway or hostile body before it is
    /// buffered and written to `DiskCache` (BP-REP-001).
    public static let defaultMaximumResponseBytes = 8 * 1024 * 1024

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
    /// With `allowRedirect`, a redirect is followed only to an HTTPS target
    /// the predicate accepts (same policy as `sendBounded`). A refused
    /// redirect cancels the task before the target is requested and throws
    /// `AppError.transport`; nothing is written. nil keeps URLSession's
    /// default redirect handling.
    public func download(
        _ request: URLRequest,
        allowRedirect: (@Sendable (URL) -> Bool)? = nil
    ) async throws -> (URL, HTTPURLResponse) {
        try Task.checkCancellation()
        var req = request
        if req.timeoutInterval <= 0 || req.timeoutInterval > 3600 {
            req.timeoutInterval = max(defaultTimeout, 120)
        }
        let redirectDelegate = allowRedirect.flatMap { allow in
            request.url.map {
                BoundedRedirectDelegate(origin: $0, allow: allow, cancelOnRefusal: true)
            }
        }
        let tmp: URL
        let response: URLResponse
        do {
            (tmp, response) = try await session.download(for: req, delegate: redirectDelegate)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlErr as URLError {
            if urlErr.code == .cancelled {
                // Our own refusal cancels the task too; only a caller's
                // cancellation is a CancellationError.
                if redirectDelegate?.didRefuse == true {
                    throw AppError.transport("download redirect refused")
                }
                throw CancellationError()
            }
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

    /// Sends `request` with URLSession's default redirect handling (vendor
    /// APIs keep whatever redirects they rely on today) and refuses a body
    /// larger than `maximumResponseBytes` instead of buffering it whole.
    public func send(
        _ request: URLRequest,
        maximumResponseBytes: Int = HTTPClient.defaultMaximumResponseBytes
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        return try await readBounded(request, maximumResponseBytes: maximumResponseBytes,
                                     delegate: nil)
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
        guard let origin = request.url else {
            throw AppError.transport("invalid bounded HTTP request")
        }
        let redirectDelegate = BoundedRedirectDelegate(origin: origin, allow: allowRedirect)
        return try await readBounded(request, maximumResponseBytes: maximumResponseBytes,
                                     delegate: redirectDelegate)
    }

    /// Bytes buffered between cancellation checks and appends in
    /// `readBounded` (PERF-MAE-002).
    static let readChunkBytes = 64 * 1024

    /// Shared capped streaming read. A nil `delegate` leaves redirects to the
    /// session's own policy, exactly as `session.data(for:)` did for `send`.
    /// The one place the cap itself is validated.
    private func readBounded(
        _ request: URLRequest,
        maximumResponseBytes: Int,
        delegate: (any URLSessionTaskDelegate)?
    ) async throws -> (Data, HTTPURLResponse) {
        guard maximumResponseBytes >= 0 else {
            throw AppError.transport("invalid bounded HTTP request")
        }
        var req = request
        if req.timeoutInterval <= 0 || req.timeoutInterval > 3600 {
            req.timeoutInterval = defaultTimeout
        }
        do {
            let (bytes, response) = try await session.bytes(for: req, delegate: delegate)
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
            // Per byte only an integer compare and an array append; the
            // cancellation check and the copy into `data` run once per chunk.
            // Doing both per byte made every vendor fetch ~100x slower to read.
            let chunkBytes = Self.readChunkBytes
            var chunk: [UInt8] = []
            chunk.reserveCapacity(chunkBytes)
            for try await byte in bytes {
                guard data.count + chunk.count < maximumResponseBytes else {
                    throw AppError.transport(
                        "HTTP response exceeds \(maximumResponseBytes) bytes"
                    )
                }
                chunk.append(byte)
                if chunk.count == chunkBytes {
                    try Task.checkCancellation()
                    data.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            data.append(contentsOf: chunk)
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
    /// Downloads cancel on refusal: a refused redirect otherwise leaves the
    /// download without a final response, which the async download API does
    /// not survive (it traps under URLProtocol stubs).
    private let cancelOnRefusal: Bool
    private let refused = OSAllocatedUnfairLock(initialState: false)

    var didRefuse: Bool { refused.withLock { $0 } }

    init(origin: URL, allow: (@Sendable (URL) -> Bool)?, cancelOnRefusal: Bool = false) {
        scheme = origin.scheme?.lowercased()
        host = origin.host?.lowercased()
        port = origin.port
        self.allow = allow
        self.cancelOnRefusal = cancelOnRefusal
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
            if cancelOnRefusal {
                refused.withLock { $0 = true }
                task.cancel()
            }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
