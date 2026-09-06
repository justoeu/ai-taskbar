import Foundation

/// URLProtocol subclass that intercepts every request and serves a canned
/// response set by `Self.handler`. Used by provider tests to feed JSON
/// fixtures without hitting the network.
public final class StubURLProtocol: URLProtocol {
    public struct CannedResponse {
        public var status: Int
        public var data: Data
        public var headers: [String: String]
        /// Optional redirect emitted through URLProtocol's redirect callback.
        /// This exercises URLSession redirect delegates without real network I/O.
        public var redirectURL: URL?
        /// When set, the protocol surfaces this error to the caller via
        /// `didFailWithError`. Used to exercise the `URLError` → `AppError`
        /// translation paths in HTTPClient.
        public var error: Error?
        public init(status: Int = 200,
                    data: Data,
                    headers: [String: String] = [:],
                    redirectURL: URL? = nil,
                    error: Error? = nil) {
            self.status = status
            self.data = data
            self.headers = headers
            self.redirectURL = redirectURL
            self.error = error
        }

        /// Builds a response that surfaces a `URLError` of the given code.
        public static func failing(_ code: URLError.Code) -> CannedResponse {
            CannedResponse(status: 0, data: Data(), error: URLError(code))
        }
    }

    /// Closure invoked for each request. Tests set this in `setUp`; the
    /// fixture decides what to return based on URL / method.
    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var handlerStorage: ((URLRequest) -> CannedResponse)?
    private nonisolated(unsafe) static var capturedStorage: [URLRequest] = []

    public static var handler: ((URLRequest) -> CannedResponse)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return handlerStorage
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            handlerStorage = newValue
        }
    }

    /// Captured requests for assertions on headers, methods, bodies.
    public static var captured: [URLRequest] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return capturedStorage
    }

    public static func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        handlerStorage = nil
        capturedStorage = []
    }

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        Self.stateLock.lock()
        Self.capturedStorage.append(request)
        let handler = Self.handlerStorage
        Self.stateLock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "StubURLProtocol", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no handler set"]))
            return
        }
        let resp = handler(request)
        if let err = resp.error {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        if let redirectURL = resp.redirectURL {
            let redirectResponse = HTTPURLResponse(
                url: request.url ?? URL(string: "about:blank")!,
                statusCode: resp.status,
                httpVersion: "HTTP/1.1",
                headerFields: resp.headers.merging(
                    ["Location": redirectURL.absoluteString],
                    uniquingKeysWith: { current, _ in current }
                )
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: redirectURL),
                redirectResponse: redirectResponse
            )
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let httpResp = HTTPURLResponse(
            url: request.url ?? URL(string: "about:blank")!,
            statusCode: resp.status,
            httpVersion: "HTTP/1.1",
            headerFields: resp.headers
        )!
        client?.urlProtocol(self, didReceive: httpResp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: resp.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    public override func stopLoading() {}
}
