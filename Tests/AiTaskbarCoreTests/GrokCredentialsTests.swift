import Testing
import Foundation
@testable import AiTaskbarCore
import AiTaskbarTesting

@Suite("GrokCredentials and GrokAuthReader")
struct GrokCredentialsTests {
    let tmp: URL

    init() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-grok-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
    }

    @Test("reads valid auth.json with scoped map")
    func reads_valid_auth_json() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("auth.json")
        try Fixtures.grokAuthJSON.write(to: file, atomically: true, encoding: .utf8)

        let reader = GrokAuthReader(path: file)
        let entry = try reader.read()
        #expect(entry.key == "test-grok-token-12345")
        expectTrue(entry.userId == "b1a00492-073a-47ea-816f-4c329264a828")
        expectTrue(entry.email == "user@example.com")
        expectTrue(entry.teamId == "test-team")
        expectFalse(entry.isExpired)
    }

    @Test("detects expired token correctly")
    func detects_expired_token() throws {
        let expiredEntry = GrokAuthEntry(
            key: "expired-token",
            expiresAt: "2020-01-01T00:00:00Z"
        )
        expectTrue(expiredEntry.isExpired)

        let validEntry = GrokAuthEntry(
            key: "future-token",
            expiresAt: "2099-01-01T00:00:00Z"
        )
        expectFalse(validEntry.isExpired)
    }

    @Test("missing auth.json throws AppError.credentials")
    func missing_file_throws() throws {
        let file = tmp.appendingPathComponent("nonexistent-auth.json")
        let reader = GrokAuthReader(path: file)
        #expect(throws: AppError.self) {
            _ = try reader.read()
        }
    }

    @Test("empty key throws AppError")
    func empty_key_throws() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("auth.json")
        let emptyJSON = #"{"scope":{"key":""}}"#
        try emptyJSON.write(to: file, atomically: true, encoding: .utf8)

        let reader = GrokAuthReader(path: file)
        #expect(throws: AppError.self) {
            _ = try reader.read()
        }
    }

    @Test("reads subscription tier display from settings_cache.json")
    func reads_settings_cache_tier() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("settings_cache.json")
        let content = """
        {
          "payload": "{\\"settings\\":{\\"subscription_tier_display\\":\\"SuperGrok Heavy\\"}}"
        }
        """
        try content.write(to: file, atomically: true, encoding: .utf8)
        let tier = GrokLocalCache.readSubscriptionTierDisplay(at: file)
        expectTrue(tier == "SuperGrok Heavy")
    }
}
