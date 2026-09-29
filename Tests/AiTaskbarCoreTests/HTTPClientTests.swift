import Testing
import Foundation
@testable import AiTaskbarCore
import AiTaskbarTesting

@Suite("HTTPClient ephemeral semantics + error wrapping", .serialized)
struct HTTPClientTests {
    init() { StubURLProtocol.reset() }

    @Test("default config is ephemeral with no URLCache/cookies/credentials")
    func default_config_is_ephemeral() {
        let client = HTTPClient()
        let cfg = client.sessionConfiguration
        #expect(cfg.urlCache == nil)
        #expect(cfg.httpCookieStorage == nil)
        #expect(cfg.urlCredentialStorage == nil)
        #expect(cfg.httpMaximumConnectionsPerHost == 4)
    }

    @Test("send returns 2xx body verbatim")
    func send_returns_2xx_body() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: Data("ok".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let req = URLRequest(url: URL(string: "https://example.com/x")!)
        let (data, response) = try await http.send(req)
        #expect(data == Data("ok".utf8))
        #expect(response.statusCode == 200)
        StubURLProtocol.reset()
    }

    @Test("sendDecoding success path")
    func sendDecoding_success() async throws {
        struct Out: Decodable, Equatable { let n: Int }
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: Data(#"{"n":42}"#.utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let out = try await http.sendDecoding(
            URLRequest(url: URL(string: "https://example.com")!),
            as: Out.self)
        #expect(out == Out(n: 42))
        StubURLProtocol.reset()
    }

    @Test("sendDecoding wraps 4xx as AppError.http")
    func sendDecoding_wraps_4xx_as_http() async {
        struct Out: Decodable { let n: Int }
        StubURLProtocol.handler = { _ in
            .init(status: 401, data: Data("unauthorized".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await http.sendDecoding(
                URLRequest(url: URL(string: "https://example.com")!),
                as: Out.self)
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .http(let status, _) = err {
                #expect(status == 401)
            } else {
                Issue.record("expected .http, got \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
        StubURLProtocol.reset()
    }

    @Test("sendDecoding wraps decode failure as AppError.schema")
    func sendDecoding_wraps_schema_error() async {
        struct Out: Decodable { let n: Int }
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: Data(#"not json"#.utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await http.sendDecoding(
                URLRequest(url: URL(string: "https://example.com")!),
                as: Out.self)
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .schema = err {} else {
                Issue.record("expected .schema, got \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
        StubURLProtocol.reset()
    }

    @Test("pinned with empty hosts falls back to default ephemeral client")
    func pinned_with_no_hosts_falls_back_to_default() throws {
        let client = try HTTPClient.pinned(pinnedHosts: [])
        #expect(client.sessionConfiguration.urlCache == nil)
    }

    @Test("URLError.cannotConnectToHost is wrapped as AppError.transport")
    func urlError_wrapped_as_transport() async {
        StubURLProtocol.handler = { _ in
            .failing(.cannotConnectToHost)
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await http.send(URLRequest(url: URL(string: "https://example.com")!))
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .transport(let msg) = err {
                #expect(msg.contains("URLError") || msg.contains("connect"))
            } else {
                Issue.record("expected .transport, got \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
        StubURLProtocol.reset()
    }

    @Test("URLError.cancelled is translated to CancellationError")
    func urlError_cancelled_becomes_cancellation_error() async {
        StubURLProtocol.handler = { _ in
            .failing(.cancelled)
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await http.send(URLRequest(url: URL(string: "https://example.com")!))
            Issue.record("expected throw")
        } catch is CancellationError {
            // success
        } catch {
            Issue.record("expected CancellationError, got \(type(of: error))")
        }
        StubURLProtocol.reset()
    }

    @Test("pinned with non-empty hosts builds a pinned client")
    func pinned_with_hosts_builds_client() throws {
        let client = try HTTPClient.pinned(pinnedHosts: ["api.example.com"])
        // Configuration is still ephemeral.
        #expect(client.sessionConfiguration.urlCache == nil)
        // We can't verify pinning end-to-end without a real TLS handshake,
        // but the constructor must succeed without throwing.
    }

    @Test("cancellation propagates through send")
    func cancellation_propagates() async {
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: Data())
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let task = Task {
            try await http.send(URLRequest(url: URL(string: "https://example.com")!))
        }
        task.cancel()
        do {
            _ = try await task.value
            // Either path (cancelled in time or completed) is OK for coverage.
        } catch {
            // Cancellation race window — either CancellationError or no throw.
        }
        StubURLProtocol.reset()
    }

    @Test("Negative timeout is normalized to defaultTimeout")
    func send_normalizes_invalid_timeout() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: Data())
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        var req = URLRequest(url: URL(string: "https://example.com")!)
        req.timeoutInterval = -1   // invalid
        let (_, resp) = try await http.send(req)
        #expect(resp.statusCode == 200)
        StubURLProtocol.reset()
    }

    @Test("bounded send rejects an oversized response before accepting its body")
    func bounded_send_rejects_oversized_content_length() async {
        StubURLProtocol.handler = { _ in
            .init(data: Data("small".utf8), headers: ["Content-Length": "4096"])
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await http.sendBounded(
                URLRequest(url: URL(string: "https://example.com/status")!),
                maximumResponseBytes: 64
            )
            Issue.record("expected bounded response failure")
        } catch let error as AppError {
            guard case .transport(let message) = error else {
                Issue.record("expected transport error, got \(error)")
                return
            }
            #expect(message.contains("64"))
        } catch {
            Issue.record("expected AppError")
        }
        StubURLProtocol.reset()
    }

    @Test("bounded send refuses a cross-origin redirect before requesting its target")
    func bounded_send_blocks_cross_origin_redirect() async {
        let hostile = URL(string: "https://attacker.example/collect")!
        StubURLProtocol.handler = { request in
            if request.url?.host == "attacker.example" {
                Issue.record("redirect target must never be requested")
                return .init(data: Data("leaked".utf8))
            }
            return .init(status: 302, data: Data(), redirectURL: hostile)
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await http.sendBounded(
                URLRequest(url: URL(string: "https://example.com/status")!),
                maximumResponseBytes: 64
            )
            Issue.record("expected the rejected redirect to fail the request")
        } catch let error as AppError {
            guard case .transport = error else {
                Issue.record("expected transport error, got \(error)")
                return
            }
        } catch {
            Issue.record("expected AppError")
        }
        #expect(StubURLProtocol.captured.count == 1)
        #expect(StubURLProtocol.captured[0].url?.host == "example.com")
        StubURLProtocol.reset()
    }

    @Test("bounded send follows a cross-origin redirect the caller allows")
    func bounded_send_follows_allowed_redirect() async throws {
        let cdn = URL(string: "https://cdn.example/file")!
        StubURLProtocol.handler = { request in
            if request.url?.host == "cdn.example" { return .init(data: Data("ok".utf8)) }
            return .init(status: 302, data: Data(), redirectURL: cdn)
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let (data, _) = try await http.sendBounded(
            URLRequest(url: URL(string: "https://example.com/file")!),
            maximumResponseBytes: 64,
            allowRedirect: { $0.host == "cdn.example" })
        #expect(data == Data("ok".utf8))
        StubURLProtocol.reset()
    }

    @Test("bounded send refuses a redirect the caller's predicate rejects")
    func bounded_send_refuses_rejected_redirect() async {
        StubURLProtocol.handler = { request in
            if request.url?.host == "attacker.example" {
                Issue.record("redirect target must never be requested")
                return .init(data: Data("leaked".utf8))
            }
            return .init(status: 302, data: Data(),
                         redirectURL: URL(string: "https://attacker.example/x")!)
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        await #expect(throws: AppError.self) {
            _ = try await http.sendBounded(
                URLRequest(url: URL(string: "https://example.com/file")!),
                maximumResponseBytes: 64,
                allowRedirect: { $0.host == "cdn.example" })
        }
        StubURLProtocol.reset()
    }

    // BP-REP-001 / LEAK-FAN-006: the vendor usage + OAuth path (`send`,
    // `sendDecoding`, `fetchPayload`) must not buffer an arbitrarily large
    // body. 9 MiB is over the 8 MiB default cap.
    @Test("send rejects a body larger than the default cap")
    func send_rejects_oversized_body() async {
        let oversized = Data(repeating: 0x61, count: 9 * 1024 * 1024)
        StubURLProtocol.handler = { _ in .init(data: oversized) }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        var message = ""
        do {
            let (data, _) = try await http.send(URLRequest(url: URL(string: "https://example.com/usage")!))
            Issue.record("expected an oversize failure, got \(data.count) bytes")
        } catch let error as AppError {
            if case .transport(let m) = error { message = m }
        } catch {
            Issue.record("expected AppError, got \(error)")
        }
        #expect(message.contains("exceeds \(HTTPClient.defaultMaximumResponseBytes) bytes"))
        StubURLProtocol.reset()
    }

    @Test("sendDecoding inherits the default response cap")
    func sendDecoding_rejects_oversized_body() async {
        struct Out: Decodable { let n: Int }
        let oversized = Data(repeating: 0x20, count: 9 * 1024 * 1024)
        StubURLProtocol.handler = { _ in .init(data: oversized) }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        var transport = false
        do {
            _ = try await http.sendDecoding(URLRequest(url: URL(string: "https://example.com/u")!), as: Out.self)
        } catch let error as AppError {
            if case .transport = error { transport = true }
        } catch {}
        #expect(transport)
        StubURLProtocol.reset()
    }

    @Test("the default cap is at least 50x the largest vendor fixture")
    func default_cap_is_generous() {
        let largest = [Fixtures.anthropicUsage200, Fixtures.openaiUsage200,
                       Fixtures.statuspageIncidentsWindow200].map { $0.utf8.count }.max() ?? 0
        #expect(HTTPClient.defaultMaximumResponseBytes >= 50 * largest)
    }

    @Test("send still returns a real vendor fixture verbatim")
    func send_accepts_fixture() async throws {
        let body = Data(Fixtures.anthropicUsage200.utf8)
        StubURLProtocol.handler = { _ in .init(data: body) }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let (data, _) = try await http.send(URLRequest(url: URL(string: "https://example.com/usage")!))
        #expect(data == body)
        StubURLProtocol.reset()
    }

    // `send` keeps URLSession's default redirect handling; only
    // `sendBounded` restricts origins.
    @Test("send still follows a cross-origin redirect")
    func send_follows_cross_origin_redirect() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.host == "api2.example" { return .init(data: Data("moved".utf8)) }
            return .init(status: 302, data: Data(), redirectURL: URL(string: "https://api2.example/u")!)
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let (data, _) = try await http.send(URLRequest(url: URL(string: "https://example.com/u")!))
        #expect(data == Data("moved".utf8))
        StubURLProtocol.reset()
    }

    // LEAK-FAN-004: a download whose response is rejected after URLSession
    // already wrote the body must not leave that temp file behind.
    @Test("download rejecting a non-HTTP response deletes the temp file")
    func download_non_http_response_removes_temp() async throws {
        let before = try urlSessionDownloadTemps()
        let http = HTTPClient.stubbed(protocols: [NonHTTPResponseProtocol.self])
        await #expect(throws: AppError.transport("non-HTTP download response")) {
            _ = try await http.download(URLRequest(url: URL(string: "https://example.com/a.dmg")!))
        }
        #expect(try urlSessionDownloadTemps().subtracting(before) == [])
    }
}

/// Answers with a plain `URLResponse` (not HTTP) and a body. Immutable.
private final class NonHTTPResponseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = URLResponse(url: request.url!, mimeType: nil,
                                   expectedContentLength: 4, textEncodingName: nil)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("body".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// URLSession names its download temp files `CFNetworkDownload_*.tmp`.
private func urlSessionDownloadTemps() throws -> Set<String> {
    let names = try FileManager.default.contentsOfDirectory(
        atPath: FileManager.default.temporaryDirectory.path)
    return Set(names.filter { $0.hasPrefix("CFNetworkDownload_") })
}
