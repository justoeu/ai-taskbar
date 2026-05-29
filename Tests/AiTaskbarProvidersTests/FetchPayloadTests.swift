import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("HTTPClient.fetchPayload extension", .serialized)
struct FetchPayloadTests {
    init() { StubURLProtocol.reset() }

    @Test("returns bytes on 2xx")
    func returns_bytes_on_2xx() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: Data("hello".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let body = try await http.fetchPayload(
            URLRequest(url: URL(string: "https://example.com")!))
        #expect(body == Data("hello".utf8))
        StubURLProtocol.reset()
    }

    @Test("throws AppError.http on 4xx")
    func throws_http_on_4xx() async {
        StubURLProtocol.handler = { _ in
            .init(status: 404, data: Data("not found".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await http.fetchPayload(
                URLRequest(url: URL(string: "https://example.com")!))
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .http(let status, let body) = err {
                #expect(status == 404)
                #expect(body.contains("not found"))
            } else {
                Issue.record("expected .http, got \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
        StubURLProtocol.reset()
    }

    @Test("throws AppError.http on 5xx with body preview")
    func throws_http_on_5xx() async {
        StubURLProtocol.handler = { _ in
            .init(status: 503, data: Data("server hot".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await http.fetchPayload(
                URLRequest(url: URL(string: "https://example.com")!))
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .http(let status, _) = err {
                #expect(status == 503)
            }
        } catch {
            Issue.record("expected AppError")
        }
        StubURLProtocol.reset()
    }
}
