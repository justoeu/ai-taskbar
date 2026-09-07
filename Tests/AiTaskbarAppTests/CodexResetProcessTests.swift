import Foundation
import Testing
import AiTaskbarCore
@testable import AiTaskbarApp

@Suite("Codex reset process transport", .serialized)
struct CodexResetProcessTests {
    private func process(_ script: String, timeout: TimeInterval = 1) throws -> CodexResetProcess {
        try CodexResetProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script], timeout: timeout, validateExecutable: { _ in true })
    }

    @Test("untrusted executable is rejected before any bearer can be sent")
    func signature_gate() {
        expectFalse(CodexResetProcess.trustedExecutable(URL(fileURLWithPath: "/bin/sh")))
        #expect(throws: OpenAIResetError.unavailable) { try CodexResetProcess(executable: nil) }
        #expect(throws: OpenAIResetError.unavailable) {
            try CodexResetProcess(executable: URL(fileURLWithPath: "/bin/sh"))
        }
    }

    @Test("installed official CLI accepts initialize without any account or reset")
    func installed_cli_initialize() throws {
        guard let executable = CodexResetProcess.executable else { return } // Optional integration on hosts with Codex.
        let rpc = try CodexResetProcess(executable: executable)
        let result = try rpc.request("initialize", params: [
            "clientInfo": .object(["name": .string("ai-taskbar-test"), "version": .string("1")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ])
        expectFalse(result.isEmpty)
        try rpc.notify("initialized")
    }

    @Test("JSON frames skip notifications and directory is private then removed")
    func framing_and_isolation() throws {
        var directory: String?
        do {
            let rpc = try process(#"read line; printf '%s\n' '{"method":"notice"}'; printf '{"id":1,"result":{"directory":"%s"}}\n' "$CODEX_HOME"; read line"#)
            let response = try rpc.request("test", params: [:])
            let path = try #require(response["directory"]?.stringValue)
            directory = path
            let mode = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
            #expect(mode.intValue & 0o777 == 0o700)
            expectFalse(FileManager.default.fileExists(atPath: path + "/auth.json"))
        }
        expectFalse(FileManager.default.fileExists(atPath: try #require(directory)))
    }

    @Test("timeout, malformed frames, EOF and renewal request fail closed")
    func failures() throws {
        let timed = try process("read line; exec /bin/sleep 2", timeout: 0.1)
        #expect(throws: OpenAIResetError.timeout) { try timed.request("test", params: [:]) }
        let invalid = try process(#"read line; printf '%s\n' 'not-json'; read line"#)
        #expect(throws: OpenAIResetError.protocolFailure) { try invalid.request("test", params: [:]) }
        let eof = try process("read line; exit 0")
        #expect(throws: OpenAIResetError.protocolFailure) { try eof.request("test", params: [:]) }
        let renewal = try process(#"read line; printf '%s\n' '{"method":"account/chatgptAuthTokens/refresh","id":9}'; read line"#)
        #expect(throws: OpenAIResetError.authorization) { try renewal.request("test", params: [:]) }
    }
}
