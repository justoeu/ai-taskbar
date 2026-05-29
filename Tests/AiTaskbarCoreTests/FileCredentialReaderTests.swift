import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("FileCredentialReader for ~/.codex/auth.json")
struct FileCredentialReaderTests {
    let tmp: URL

    init() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-codex-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
    }

    private func write(_ json: String, to file: URL) throws {
        try json.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test("reads full auth.json with account_id + extra fields")
    func reads_full_auth_json() throws {
        let file = tmp.appendingPathComponent("auth.json")
        let body = #"""
        {
          "tokens": {
            "access_token": "a",
            "refresh_token": "r",
            "id_token": "i"
          },
          "account_id": "acc-123",
          "last_refresh": "2026-05-28T12:00:00Z"
        }
        """#
        try write(body, to: file)
        let reader = FileCredentialReader(path: file)
        let auth = try reader.read()
        #expect(auth.tokens.accessToken == "a")
        #expect(auth.tokens.refreshToken == "r")
        #expect(auth.tokens.idToken == "i")
        #expect(auth.accountId == "acc-123")
        // Unknown extras are round-tripped
        #expect(auth.unknownTopLevel["last_refresh"] == .string("2026-05-28T12:00:00Z"))
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("falls back to account-id (hyphen variant)")
    func falls_back_to_account_hyphen_variant() throws {
        let file = tmp.appendingPathComponent("auth.json")
        try write(#"""
        {
          "tokens": { "access_token":"a","refresh_token":"r","id_token":"i" },
          "account-id": "acc-hyphen"
        }
        """#, to: file)
        let reader = FileCredentialReader(path: file)
        let auth = try reader.read()
        #expect(auth.accountId == "acc-hyphen")
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("missing file → AppError.credentials")
    func missing_file_throws_credentials_error() {
        let reader = FileCredentialReader(
            path: tmp.appendingPathComponent("does-not-exist.json"))
        do {
            _ = try reader.read()
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .credentials = err {} else {
                Issue.record("expected .credentials, got \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
    }

    @Test("invalid JSON → AppError.schema")
    func invalid_json_throws_schema_error() throws {
        let file = tmp.appendingPathComponent("auth.json")
        try write("not json", to: file)
        let reader = FileCredentialReader(path: file)
        do {
            _ = try reader.read()
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .schema = err {} else {
                Issue.record("expected .schema, got \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("missing `tokens` object → AppError.schema")
    func missing_tokens_object_throws_schema() throws {
        let file = tmp.appendingPathComponent("auth.json")
        try write(#"{"account_id":"acc"}"#, to: file)
        let reader = FileCredentialReader(path: file)
        do {
            _ = try reader.read()
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .schema(let msg) = err {
                #expect(msg.contains("tokens"))
            }
        } catch {
            Issue.record("expected AppError")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("missing access_token → AppError.schema")
    func missing_access_token_throws_schema() throws {
        let file = tmp.appendingPathComponent("auth.json")
        try write(#"""
        { "tokens": { "refresh_token":"r","id_token":"i" } }
        """#, to: file)
        let reader = FileCredentialReader(path: file)
        do {
            _ = try reader.read()
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .schema(let msg) = err {
                #expect(msg.contains("access_token"))
            }
        } catch {
            Issue.record("expected AppError")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("writeBack preserves unknown top-level + sets 0o600")
    func writeback_preserves_unknown_and_sets_perms() throws {
        let file = tmp.appendingPathComponent("auth.json")
        let extras: [String: JSONValue] = ["last_refresh": .string("now")]
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: "a2", refreshToken: "r2", idToken: "i2"),
            accountId: "acc-2",
            unknownTopLevel: extras
        )
        let reader = FileCredentialReader(path: file)
        try reader.writeBack(auth)

        // Perms must be 0o600 because this file holds OAuth tokens.
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)

        // Re-read confirms round-trip including the unknown extras.
        let back = try reader.read()
        #expect(back.tokens.accessToken == "a2")
        #expect(back.accountId == "acc-2")
        #expect(back.unknownTopLevel["last_refresh"] == .string("now"))
        try? FileManager.default.removeItem(at: tmp)
    }
}
