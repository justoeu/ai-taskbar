import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("EnvOrConfigCredentialReader resolution order")
struct EnvOrConfigCredentialReaderTests {
    @Test("reads from env var when present")
    func reads_from_env() throws {
        let name = "AI_TASKBAR_TEST_KEY_\(UUID().uuidString.prefix(8))"
        setenv(name, "from-env", 1)
        defer { unsetenv(name) }
        let reader = EnvOrConfigCredentialReader(
            envVarName: name, inlineKey: "from-inline", vendorName: "Test")
        let key = try reader.read()
        #expect(key == "from-env", "env should win over inline")
    }

    @Test("falls back to inline key when env unset")
    func falls_back_to_inline() throws {
        let reader = EnvOrConfigCredentialReader(
            envVarName: "AI_TASKBAR_DEFINITELY_UNSET_\(UUID().uuidString.prefix(8))",
            inlineKey: "inline-key",
            vendorName: "Test")
        #expect(try reader.read() == "inline-key")
    }

    @Test("trims surrounding whitespace from env value")
    func trims_whitespace_env() throws {
        let name = "AI_TASKBAR_TEST_WS_\(UUID().uuidString.prefix(8))"
        // ALL-whitespace env var should be considered "unset" and fall back.
        setenv(name, "   ", 1)
        defer { unsetenv(name) }
        let reader = EnvOrConfigCredentialReader(
            envVarName: name, inlineKey: "inline", vendorName: "Test")
        #expect(try reader.read() == "inline")
    }

    @Test("throws AppError.disabled when no source is set")
    func throws_disabled_when_none() {
        let reader = EnvOrConfigCredentialReader(
            envVarName: "AI_TASKBAR_NONE_\(UUID().uuidString.prefix(8))",
            inlineKey: nil,
            vendorName: "Test")
        do {
            _ = try reader.read()
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .disabled(let msg) = err {
                #expect(msg.contains("Test"))
            } else {
                Issue.record("expected .disabled, got \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
    }

    @Test("empty (after trim) inline key counts as unset")
    func empty_inline_counts_unset() {
        let reader = EnvOrConfigCredentialReader(
            envVarName: "AI_TASKBAR_NONE_\(UUID().uuidString.prefix(8))",
            inlineKey: "   ",
            vendorName: "Test")
        #expect(throws: AppError.self) { _ = try reader.read() }
    }
}
