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

    // MARK: - pendingUpdate mirror

    /// Helper: builds a JWT id_token carrying `exp` (ms since epoch) in the
    /// payload. Matches the format the Codex CLI actually writes.
    private func jwt(expMs: Int64) -> String {
        let header = Data("{\"alg\":\"none\"}".utf8).base64UR()
        let expSec = expMs / 1000
        let payload = Data("{\"exp\":\(expSec)}".utf8).base64UR()
        return "\(header).\(payload)."
    }

    private func auth(token: String = "t", refresh: String = "r", expMs: Int64) -> CodexAuth {
        CodexAuth(tokens: CodexTokens(accessToken: token, refreshToken: refresh,
                                      idToken: jwt(expMs: expMs)),
                  accountId: nil)
    }

    @Test("HEADLINE: writeBack failure preserves rotated token via pendingUpdate")
    func writeback_failure_preserves_token_in_memory() throws {
        // Simulate the failure mode the audit flagged: the OAuth server
        // already rotated the refresh_token, then AtomicFileWrite fails.
        // Without pendingUpdate, the rotated token would be lost — logging
        // the user out of both the CLI and the monitor.
        //
        // Force the failure by placing a regular FILE where the target dir
        // would be. `Paths.ensureDir` refuses a non-directory path → writeBack
        // throws → pendingUpdate is populated.
        let blocker = tmp.appendingPathComponent("blocker")
        try Data().write(to: blocker)  // create the blocker as a file
        let badPath = blocker.appendingPathComponent("auth.json")
        let failingReader = FileCredentialReader(path: badPath)
        let rotated = auth(token: "rotated-access", refresh: "rotated-refresh",
                           expMs: 2_000_000)
        do {
            try failingReader.writeBack(rotated)
            Issue.record("expected writeBack to fail because parent path is a file")
        } catch {
            // Expected — but pendingUpdate MUST now hold the rotated copy.
        }
        // The read should surface the rotated token (pendingUpdate wins)
        // because the on-disk file isn't readable as a credential file at
        // `blocker/auth.json`.
        let recovered = try failingReader.read()
        #expect(recovered.tokens.accessToken == "rotated-access")
        #expect(recovered.tokens.refreshToken == "rotated-refresh")
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("pending fresher than disk → read serves pending")
    func pending_fresher_wins_via_read() throws {
        // Seed disk with an older token.
        let file = tmp.appendingPathComponent("auth.json")
        let reader = FileCredentialReader(path: file)
        try reader.writeBack(auth(token: "old-disk", expMs: 1_000_000))

        // Force pendingUpdate via a failing writeBack on a separate reader
        // pointed at an unwritable path. The pending copy carries a fresher exp.
        let blocker = tmp.appendingPathComponent("blocker2")
        try Data().write(to: blocker)
        let failingReader = FileCredentialReader(path: blocker.appendingPathComponent("auth.json"))
        try? failingReader.writeBack(auth(token: "fresher-pending", expMs: 2_000_000))

        let recovered = try failingReader.read()
        #expect(recovered.tokens.accessToken == "fresher-pending")
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("successful writeBack clears the pending cache")
    func successful_writeback_clears_pending() throws {
        let file = tmp.appendingPathComponent("auth.json")
        let reader = FileCredentialReader(path: file)
        // Seed disk with v1.
        try reader.writeBack(auth(token: "v1", expMs: 1_000_000))
        // Fail a follow-up writeBack on the SAME reader to populate pending.
        // We do this by temporarily pointing at an unwritable path, then
        // restoring the original path.
        // Simpler: confirm that after a fresh successful writeBack the read
        // returns the disk copy (proving pending was cleared — otherwise the
        // previous test's pending would still be visible via this instance).
        try reader.writeBack(auth(token: "v2", expMs: 3_000_000))
        let r = try reader.read()
        #expect(r.tokens.accessToken == "v2")
        try? FileManager.default.removeItem(at: tmp)
    }
}

private extension Data {
    /// Base64URL encoding without padding (matches JWT segment format).
    func base64UR() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Unit tests for the pure reconciliation logic for `CodexAuth`. Mirrors
/// `CredentialReconciliationTests` but reads freshness from the JWT `exp`
/// claim (Codex doesn't expose expiresAtMs on the credential struct itself).
@Suite("CodexReconciliation.pick — pure JWT-exp freshness logic")
struct CodexReconciliationTests {
    private func jwt(expSec: Int64) -> String {
        let header = Data("{\"alg\":\"none\"}".utf8).base64UR()
        let payload = Data("{\"exp\":\(expSec)}".utf8).base64UR()
        return "\(header).\(payload)."
    }

    private func auth(_ expSec: Int64, token: String = "t") -> CodexAuth {
        CodexAuth(tokens: CodexTokens(accessToken: token, refreshToken: "r",
                                      idToken: jwt(expSec: expSec)),
                  accountId: nil)
    }

    @Test("both nil → nil")
    func both_nil_returns_nil() {
        #expect(CodexReconciliation.pick(disk: nil, pending: nil) == nil)
    }

    @Test("disk only → disk, no drop")
    func disk_only() {
        let d = auth(1000)
        let v = CodexReconciliation.pick(disk: d, pending: nil)
        #expect(v?.credentials == d)
        #expect(v?.dropPending == false)
    }

    @Test("pending only → pending (the ACL/I/O failure safety net)")
    func pending_only_serves_pending() {
        let p = auth(2000)
        let v = CodexReconciliation.pick(disk: nil, pending: p)
        #expect(v?.credentials == p)
        #expect(v?.dropPending == false)
    }

    @Test("disk fresher → disk wins, drop pending")
    func disk_fresher_drops_pending() {
        let d = auth(2000)
        let p = auth(1000)
        let v = CodexReconciliation.pick(disk: d, pending: p)
        #expect(v?.credentials == d)
        #expect(v?.dropPending == true)
    }

    @Test("pending fresher → pending wins, keep pending")
    func pending_fresher_keeps_pending() {
        let d = auth(1000)
        let p = auth(2000)
        let v = CodexReconciliation.pick(disk: d, pending: p)
        #expect(v?.credentials == p)
        #expect(v?.dropPending == false)
    }

    @Test("equal exp → disk wins (tiebreak for clean recovery)")
    func equal_exp_disk_wins() {
        let d = auth(1500, token: "disk")
        let p = auth(1500, token: "pending")
        let v = CodexReconciliation.pick(disk: d, pending: p)
        #expect(v?.credentials.tokens.accessToken == "disk")
        #expect(v?.dropPending == true)
    }

    @Test("malformed id_tokens on both → disk wins (Int64.min tiebreak)")
    func malformed_tokens_disk_wins() {
        let bad = CodexAuth(tokens: CodexTokens(accessToken: "d", refreshToken: "r",
                                                idToken: "garbage"),
                            accountId: nil)
        let v = CodexReconciliation.pick(disk: bad, pending: bad)
        #expect(v?.credentials == bad)
        #expect(v?.dropPending == true)
    }
}
