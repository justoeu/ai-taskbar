import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

@Suite("OAuthRefresher generic refresh flow", .serialized)
struct OAuthRefresherTests {
    init() { StubURLProtocol.reset() }

    @Test("happy-path 200 decodes Anthropic refresh response")
    func happy_path_anthropic_refresh() async throws {
        StubURLProtocol.handler = { _ in
            .init(data: Fixtures.data(Fixtures.oauthRefresh200))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let resp = try await AnthropicOAuth.refresh(refreshToken: "old.r", http: http)
        #expect(resp.access_token == "new.acc.tk")
        #expect(resp.refresh_token == "new.ref.tk")
        #expect(resp.expires_in == 28800)
        StubURLProtocol.reset()
    }

    @Test("happy-path 200 decodes OpenAI refresh response")
    func happy_path_openai_refresh() async throws {
        let body = #"""
        {"access_token":"a","refresh_token":"r","id_token":"i","expires_in":3600}
        """#
        StubURLProtocol.handler = { _ in
            .init(data: Data(body.utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        let resp = try await OpenAIOAuth.refresh(refreshToken: "old.r", http: http)
        #expect(resp.access_token == "a")
        #expect(resp.id_token == "i")
        StubURLProtocol.reset()
    }

    @Test("4xx error_description shape surfaces as AppError.credentials")
    func error_description_shape_throws_credentials_error() async {
        StubURLProtocol.handler = { _ in
            .init(status: 400, data: Data(#"{"error_description":"invalid_grant"}"#.utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await AnthropicOAuth.refresh(refreshToken: "x", http: http)
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .credentials(let msg) = err {
                #expect(msg.contains("invalid_grant"))
            } else {
                Issue.record("expected .credentials, got \(err)")
            }
        } catch {
            Issue.record("expected AppError, got \(error)")
        }
        StubURLProtocol.reset()
    }

    @Test("4xx nested error.message shape")
    func nested_error_message_shape() async {
        StubURLProtocol.handler = { _ in
            .init(status: 401, data: Data(#"{"error":{"message":"refresh expired"}}"#.utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await OpenAIOAuth.refresh(refreshToken: "x", http: http)
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .credentials(let msg) = err {
                #expect(msg.contains("refresh expired"))
            } else {
                Issue.record("expected .credentials, got \(err)")
            }
        } catch {
            Issue.record("expected AppError, got \(error)")
        }
        StubURLProtocol.reset()
    }

    @Test("4xx bare error string shape")
    func bare_error_string_shape() async {
        StubURLProtocol.handler = { _ in
            .init(status: 400, data: Data(#"{"error":"bad_request"}"#.utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await AnthropicOAuth.refresh(refreshToken: "x", http: http)
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .credentials(let msg) = err {
                #expect(msg.contains("bad_request"))
            }
        } catch {
            Issue.record("expected AppError, got \(error)")
        }
        StubURLProtocol.reset()
    }

    @Test("non-JSON error body falls through to raw prefix")
    func non_json_error_falls_through() async {
        StubURLProtocol.handler = { _ in
            .init(status: 503, data: Data("Service Unavailable".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await AnthropicOAuth.refresh(refreshToken: "x", http: http)
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .credentials(let msg) = err {
                #expect(msg.contains("Service Unavailable"))
            }
        } catch {
            Issue.record("expected AppError")
        }
        StubURLProtocol.reset()
    }

    @Test("malformed JSON body throws AppError.schema")
    func malformed_response_body_throws_schema_error() async {
        StubURLProtocol.handler = { _ in
            .init(data: Data("not json".utf8))
        }
        let http = HTTPClient.stubbed(protocols: [StubURLProtocol.self])
        do {
            _ = try await AnthropicOAuth.refresh(refreshToken: "x", http: http)
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

    @Test("OAuthErrorBody returns nil on non-JSON")
    func oauth_error_body_returns_nil_on_non_json() {
        #expect(OAuthErrorBody.parse(Data("plain text".utf8)) == nil)
    }

    @Test("OAuthErrorBody returns nil on unknown JSON shape")
    func oauth_error_body_returns_nil_on_unknown_shape() {
        #expect(OAuthErrorBody.parse(Data(#"{"weird":"shape"}"#.utf8)) == nil)
    }

    @Test("flexibleDoubleIfPresent decoder tolerates int and float")
    func flexible_double_decoder_tolerates_int_and_float() throws {
        // expires_in arrives as both Int (3600) and Float (3600.0) in the wild.
        let intBody = #"{"access_token":"a","expires_in":3600}"#
        let floatBody = #"{"access_token":"a","expires_in":3600.5}"#
        let i = try JSONDecoder().decode(AnthropicOAuth.RefreshResponse.self,
                                         from: Data(intBody.utf8))
        let f = try JSONDecoder().decode(AnthropicOAuth.RefreshResponse.self,
                                         from: Data(floatBody.utf8))
        #expect(i.expires_in == 3600)
        #expect(f.expires_in == 3600.5)
    }

    @Test("missing expires_in is a hard schema error")
    func missing_expires_in_is_a_hard_error() {
        let body = #"{"access_token":"a"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AnthropicOAuth.RefreshResponse.self,
                                          from: Data(body.utf8))
        }
    }
}
