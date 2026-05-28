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
    public static func pinned(pinnedHosts: [String],
                              auditOnly: Bool = false) -> HTTPClient {
        guard !pinnedHosts.isEmpty,
              let store = try? PinStore.defaultStore() else {
            return HTTPClient()   // no pinning configured → default ephemeral
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
