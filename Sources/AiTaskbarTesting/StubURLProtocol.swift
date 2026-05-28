import Foundation

/// URLProtocol subclass that intercepts every request and serves a canned
/// response set by `Self.handler`. Used by provider tests to feed JSON
/// fixtures without hitting the network.
public final class StubURLProtocol: URLProtocol {
    public struct CannedResponse {
        public var status: Int
        public var data: Data
        public var headers: [String: String]
        public init(status: Int = 200, data: Data, headers: [String: String] = [:]) {
            self.status = status
            self.data = data
            self.headers = headers
        }
    }

    /// Closure invoked for each request. Tests set this in `setUp`; the
    /// fixture decides what to return based on URL / method.
    public nonisolated(unsafe) static var handler: ((URLRequest) -> CannedResponse)?
    /// Captured requests for assertions on headers, methods, bodies.
    public nonisolated(unsafe) static var captured: [URLRequest] = []

    public static func reset() {
        handler = nil
        captured = []
    }

    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        Self.captured.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "StubURLProtocol", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no handler set"]))
            return
        }
        let resp = handler(request)
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
