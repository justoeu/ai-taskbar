import Foundation
import Testing

@Suite("Testing infrastructure regression controls")
struct TestingInfrastructureTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private struct Resolution: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { let version: String }
            let identity: String
            let location: String
            let state: State
        }
        let pins: [Pin]
    }

    @Test("Only the reviewed runtime dependency is resolved")
    func stableDependency() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("Package.resolved"))
        let resolution = try JSONDecoder().decode(Resolution.self, from: data)
        #expect(resolution.pins.map(\.identity).sorted() == ["tomlkit"])
        let pin = try #require(resolution.pins.first { $0.identity == "tomlkit" })
        #expect(pin.state.version == "0.6.0")
        #expect(pin.location == "https://github.com/LebJe/TOMLKit.git")
    }

    @Test("Each test module compiles the same in-repository Boolean helpers", arguments: [
        "AiTaskbarCoreTests", "AiTaskbarProvidersTests", "AiTaskbarAppTests",
    ])
    func sharedHelpers(target: String) throws {
        let link = root.appendingPathComponent("Tests/\(target)/ExpectBool.swift")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(destination == "../../Sources/AiTaskbarTestSupport/ExpectBool.swift")
        #expect(link.resolvingSymlinksInPath().path == root
            .appendingPathComponent("Sources/AiTaskbarTestSupport/ExpectBool.swift").resolvingSymlinksInPath().path)
    }

    private func runToolchain(_ arguments: [String], developerDirectory: String? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/with-test-toolchain.sh").path] + arguments
        if let developerDirectory {
            var environment = ProcessInfo.processInfo.environment
            environment["DEVELOPER_DIR"] = developerDirectory
            process.environment = environment
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("Toolchain wrapper forwards arguments without shell evaluation")
    func toolchainArguments() throws {
        let literal = "a space; $(never-execute) *"
        let result = try runToolchain(["/usr/bin/printf", "%s", literal])
        #expect(result.0 == 0)
        #expect(result.1 == literal)
    }

    @Test("Toolchain wrapper preserves command failure")
    func toolchainFailure() throws {
        let result = try runToolchain(["/usr/bin/false"])
        #expect(result.0 == 1)
    }

    @Test("Invalid explicit toolchains fail without fallback", arguments: ["", "/nonexistent/ai-taskbar-test-xcode"])
    func invalidToolchain(directory: String) throws {
        let result = try runToolchain(["/usr/bin/printf", "must not execute"], developerDirectory: directory)
        #expect(result.0 == 1)
        #expect(result.1 == "")
    }

    @Test("Warning gate covers tests, macros, linker diagnostics and narrow legacy exceptions", arguments: [
        ("Build complete!", Int32(0)),
        ("/repo/Sources/AiTaskbarCore/Example.swift:1:2: warning: unused result", Int32(1)),
        ("/repo/Tests/AiTaskbarCoreTests/Example.swift:1:2: warning: unused result", Int32(1)),
        ("macro expansion #expect:1:47: warning: actor isolation", Int32(1)),
        ("ld: warning: deployment target mismatch", Int32(1)),
        ("warning: unhandled files", Int32(1)),
        ("/repo/Sources/AiTaskbarCore/Credentials/KeychainAccessAuthorizer.swift:1:2: warning: 'SecACL' was deprecated", Int32(0)),
        ("/repo/Tests/AiTaskbarCoreTests/TemporaryKeychain.swift:1:2: warning: 'SecKeychainCreate' was deprecated", Int32(0)),
        ("/repo/Tests/AiTaskbarCoreTests/TemporaryKeychain.swift:1:2: warning: unused result", Int32(1)),
        ("   | `- warning: repeated diagnostic annotation", Int32(0)),
    ])
    func warningGate(diagnostic: String, expectedStatus: Int32) throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-taskbar-warning-test-\(UUID().uuidString).log")
        try Data((diagnostic + "\n").utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/check-swift-warnings.sh").path, log.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == expectedStatus)
    }

    // An unconditionally passing assertion is not enough to validate a test
    // framework upgrade. Each known-issue scope MUST observe its failed
    // assertion; if the failure is silently lost, withKnownIssue itself fails.
    @Test("False helper assertions are observed by the active test runner")
    func helpersReportFailures() {
        withKnownIssue("Intentional negative control: expectTrue(false)") {
            expectTrue(false)
        }
        withKnownIssue("Intentional negative control: expectFalse(true)") {
            expectFalse(true)
        }
        let absent: Bool? = nil
        withKnownIssue("Intentional negative control: absent optional") {
            expectTrue(absent ?? false)
        }
    }

    @Test("True helper assertions do not create issues")
    func helpersAcceptValidConditions() {
        expectTrue(true)
        expectFalse(false)
        let present: Bool? = true
        expectTrue(present ?? false)
        let absent: Bool? = nil
        expectFalse(absent ?? false)
    }
}
