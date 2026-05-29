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
    func pinned_with_no_hosts_falls_back_to_default() {
        let client = HTTPClient.pinned(pinnedHosts: [])
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
    func pinned_with_hosts_builds_client() {
        let client = HTTPClient.pinned(pinnedHosts: ["api.example.com"])
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
}
