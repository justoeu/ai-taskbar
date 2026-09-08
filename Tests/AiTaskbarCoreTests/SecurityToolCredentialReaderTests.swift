import Testing
import Foundation
import Security
@testable import AiTaskbarCore

/// Fake `/usr/bin/security` stand-ins: tiny shell scripts in a private temp dir.
private struct FakeSecurityTool {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-taskbar-fake-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }
    func script(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private func claudeJSON(token: String) -> String {
    #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"r","expiresAt":2000000000000}}"#
}

@Suite("SecurityToolCredentialReader — argument/output codec", .serialized)
struct SecurityToolCodecTests {
    @Test("arguments are exact-match service + account, -w, then keychain paths")
    func arguments_full() {
        let args = SecurityToolCredentialReader.arguments(
            service: "Claude Code-credentials", account: "justoeu", keychainPaths: ["/tmp/k.keychain"])
        #expect(args == ["find-generic-password", "-s", "Claude Code-credentials", "-a", "justoeu", "-w", "/tmp/k.keychain"])
    }

    @Test("nil account is passed as -a \"\" so the legacy account-less item stays an exact match")
    func arguments_no_account() {
        #expect(SecurityToolCredentialReader.arguments(service: "S", account: nil, keychainPaths: [])
                == ["find-generic-password", "-s", "S", "-a", "", "-w"])
        #expect(SecurityToolCredentialReader.arguments(service: "S", account: "", keychainPaths: [])
                == ["find-generic-password", "-s", "S", "-a", "", "-w"])
    }

    @Test("JSON output loses only its trailing newline")
    func decode_json() {
        let out = SecurityToolCredentialReader.decodeOutput(Data("{\"a\":1}\n".utf8))
        #expect(out == Data("{\"a\":1}".utf8))
    }

    @Test("hex output is decoded to the original bytes")
    func decode_hex() {
        let out = SecurityToolCredentialReader.decodeOutput(Data("7b2261223a317d\n".utf8))
        #expect(out == Data("{\"a\":1}".utf8))
    }

    @Test("hex that does not decode to JSON is left alone (all-hex API keys survive)")
    func decode_hex_non_json_passthrough() {
        let out = SecurityToolCredentialReader.decodeOutput(Data("deadbeef\n".utf8))
        #expect(out == Data("deadbeef".utf8))
    }

    @Test("empty output is nil")
    func decode_empty() {
        expectTrue(SecurityToolCredentialReader.decodeOutput(Data()) == nil)
        expectTrue(SecurityToolCredentialReader.decodeOutput(Data("\n".utf8)) == nil)
    }

    @Test("non-JSON, non-hex text passes through verbatim")
    func decode_passthrough() {
        #expect(SecurityToolCredentialReader.decodeOutput(Data("abc\n".utf8)) == Data("abc".utf8))
        #expect(SecurityToolCredentialReader.decodeOutput(Data("zz\r\n".utf8)) == Data("zz".utf8))
    }

    @Test("invalid UTF-8 output is nil")
    func decode_invalid_utf8() {
        expectTrue(SecurityToolCredentialReader.decodeOutput(Data([0xff, 0xfe])) == nil)
    }
}

@Suite("SecurityToolCredentialReader — process lifecycle", .serialized)
struct SecurityToolProcessTests {
    @Test("a cooperative tool's stdout becomes the secret")
    func read_success() throws {
        let fake = try FakeSecurityTool(); defer { fake.cleanup() }
        let exe = try fake.script("printf '%s\\n' '\(claudeJSON(token: "via-tool"))'")
        let reader = SecurityToolCredentialReader(executable: exe, timeout: 5)
        let data = try reader.read(service: "S", account: "A")
        #expect(String(decoding: data, as: UTF8.self) == claudeJSON(token: "via-tool"))
        #expect(!reader.isCoolingDown)
    }

    @Test("a non-zero exit is reported with its status")
    func read_exit_status() throws {
        let fake = try FakeSecurityTool(); defer { fake.cleanup() }
        let exe = try fake.script("exit 44")
        let reader = SecurityToolCredentialReader(executable: exe, timeout: 5)
        #expect(throws: SecurityToolCredentialReader.Failure.exited(status: 44)) {
            try reader.read(service: "S", account: "A")
        }
    }

    @Test("a hung tool is killed, reported, and puts the fallback in cooldown")
    func read_timeout_cooldown() throws {
        let fake = try FakeSecurityTool(); defer { fake.cleanup() }
        let exe = try fake.script("exec sleep 30")
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000))
        let reader = SecurityToolCredentialReader(executable: exe, timeout: 0.3, timeoutCooldown: 60,
                                                  failureCooldown: 5, now: { clock.now })
        #expect(throws: SecurityToolCredentialReader.Failure.timedOut) {
            try reader.read(service: "S", account: "A")
        }
        #expect(reader.isCoolingDown)
        #expect(throws: SecurityToolCredentialReader.Failure.coolingDown(until: Date(timeIntervalSince1970: 1_060))) {
            try reader.read(service: "S", account: "A")
        }
        clock.now = Date(timeIntervalSince1970: 1_061)
        #expect(!reader.isCoolingDown)
    }

    @Test("an ordinary failure gets the short cooldown, not the hang cooldown")
    func read_failure_short_cooldown() throws {
        let fake = try FakeSecurityTool(); defer { fake.cleanup() }
        let exe = try fake.script("exit 44")
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000))
        let reader = SecurityToolCredentialReader(executable: exe, timeout: 5, timeoutCooldown: 3600,
                                                  failureCooldown: 30, now: { clock.now })
        #expect(throws: SecurityToolCredentialReader.Failure.exited(status: 44)) {
            try reader.read(service: "S", account: "A")
        }
        #expect(throws: SecurityToolCredentialReader.Failure.coolingDown(until: Date(timeIntervalSince1970: 1_030))) {
            try reader.read(service: "S", account: "A")
        }
        clock.now = Date(timeIntervalSince1970: 1_031)
        #expect(!reader.isCoolingDown)
    }

    @Test("a missing executable is a launch failure, not a crash")
    func read_launch_failure() throws {
        let reader = SecurityToolCredentialReader(
            executable: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"), timeout: 5)
        let error = #expect(throws: SecurityToolCredentialReader.Failure.self) {
            try reader.read(service: "S", account: "A")
        }
        if case .launchFailed = error {} else { Issue.record("expected launchFailed, got \(String(describing: error))") }
    }

    @Test("empty stdout with exit 0 is undecodable")
    func read_empty_output() throws {
        let fake = try FakeSecurityTool(); defer { fake.cleanup() }
        let exe = try fake.script("exit 0")
        let reader = SecurityToolCredentialReader(executable: exe, timeout: 5)
        #expect(throws: SecurityToolCredentialReader.Failure.undecodableOutput) {
            try reader.read(service: "S", account: "A")
        }
    }

    @Test("every failure has a human-readable description")
    func failure_descriptions() {
        let cases: [SecurityToolCredentialReader.Failure] = [
            .coolingDown(until: Date(timeIntervalSince1970: 0)), .launchFailed("x"),
            .timedOut, .exited(status: 44), .undecodableOutput,
        ]
        for failure in cases {
            expectFalse((failure.errorDescription ?? "").isEmpty)
        }
    }

    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }
}

@Suite("KeychainCredentialReader — security tool fallback", .serialized)
struct KeychainCredentialReaderFallbackTests {
    private let keychain: TemporaryKeychain
    init() throws { keychain = try TemporaryKeychain() }

    private func addItem(service: String, account: String, token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseKeychain as String: keychain.reference,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(claudeJSON(token: token).utf8),
        ]
        #expect(SecItemAdd(query as CFDictionary, nil) == errSecSuccess)
    }

    @Test("an ACL-blocked direct read is served by the tool for the same account")
    func blocked_read_uses_fallback() throws {
        let fake = try FakeSecurityTool(); defer { fake.cleanup() }
        let service = "ai-taskbar-fb-\(UUID().uuidString)"
        addItem(service: service, account: "justoeu", token: "direct")
        // The fake echoes its arguments back so the test can pin exact-match targeting.
        let exe = try fake.script("""
        [ "$1" = find-generic-password ] && [ "$3" = '\(service)' ] && [ "$5" = justoeu ] || exit 99
        printf '%s\\n' '\(claudeJSON(token: "tool"))'
        """)
        let fallback = SecurityToolCredentialReader(executable: exe, timeout: 5)
        let reader = KeychainCredentialReader(
            service: service, searchList: [keychain.reference], fallback: fallback,
            secItemRead: { _, _ in errSecAuthFailed })
        #expect(try reader.read().accessToken == "tool")
        #expect(!reader.canPersistCredentials)
    }

    @Test("a locked keychain never consults the tool (it would raise the unlock dialog)")
    func locked_keychain_skips_fallback() throws {
        let fake = try FakeSecurityTool(); defer { fake.cleanup() }
        let service = "ai-taskbar-fb-\(UUID().uuidString)"
        addItem(service: service, account: "justoeu", token: "direct")
        let exe = try fake.script("printf '%s\\n' '\(claudeJSON(token: "tool"))'")
        let reader = KeychainCredentialReader(
            service: service, searchList: [keychain.reference],
            fallback: SecurityToolCredentialReader(executable: exe, timeout: 5),
            secItemRead: { _, _ in errSecInteractionNotAllowed })
        #expect(SecKeychainLock(keychain.reference) == errSecSuccess)
        #expect(!KeychainCredentialReader.isUnlocked(keychain.reference))
        let error = #expect(throws: AppError.self) { try reader.read() }
        expectTrue(error?.isKeychainACLBlocked ?? false)
        try keychain.unlock()
        #expect(KeychainCredentialReader.isUnlocked(keychain.reference))
        #expect(try reader.read().accessToken == "tool")
    }

    @Test("the fallback is handed the keychain file the item lives in")
    func fallback_receives_item_keychain_path() throws {
        let fake = try FakeSecurityTool(); defer { fake.cleanup() }
        let service = "ai-taskbar-fb-\(UUID().uuidString)"
        addItem(service: service, account: "justoeu", token: "direct")
        // $7 is the first keychain path argument; the fake records it.
        let argFile = fake.directory.appendingPathComponent("arg7")
        let exe = try fake.script("""
        printf '%s' "$7" > '\(argFile.path)'
        printf '%s\\n' '\(claudeJSON(token: "tool"))'
        """)
        let reader = KeychainCredentialReader(
            service: service, searchList: [keychain.reference],
            fallback: SecurityToolCredentialReader(executable: exe, timeout: 5),
            secItemRead: { _, _ in errSecAuthFailed })
        #expect(try reader.read().accessToken == "tool")
        // /var/folders vs /private/var/folders: compare resolved paths.
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let handed = try String(contentsOf: argFile, encoding: .utf8)
        #expect(resolved(handed) == resolved(keychain.path))
        #expect(resolved(KeychainCredentialReader.path(of: keychain.reference) ?? "") == resolved(keychain.path))
    }

    @Test("when the tool also fails, the original ACL error still drives the Authorize banner")
    func blocked_read_without_working_fallback() throws {
        let fake = try FakeSecurityTool(); defer { fake.cleanup() }
        let service = "ai-taskbar-fb-\(UUID().uuidString)"
        addItem(service: service, account: "justoeu", token: "direct")
        let exe = try fake.script("exit 44")
        let fallback = SecurityToolCredentialReader(executable: exe, timeout: 5)
        let reader = KeychainCredentialReader(
            service: service, searchList: [keychain.reference], fallback: fallback,
            secItemRead: { _, _ in errSecInteractionNotAllowed })
        let error = #expect(throws: AppError.self) { try reader.read() }
        expectTrue(error?.isKeychainACLBlocked ?? false)
    }

    @Test("no fallback configured keeps the historical ACL error")
    func blocked_read_no_fallback() throws {
        let service = "ai-taskbar-fb-\(UUID().uuidString)"
        addItem(service: service, account: "justoeu", token: "direct")
        let reader = KeychainCredentialReader(
            service: service, searchList: [keychain.reference],
            secItemRead: { _, _ in errSecAuthFailed })
        let error = #expect(throws: AppError.self) { try reader.read() }
        expectTrue(error?.isKeychainACLBlocked ?? false)
    }

    @Test("a healthy direct read never spawns the tool")
    func direct_read_skips_fallback() throws {
        let fake = try FakeSecurityTool(); defer { fake.cleanup() }
        let service = "ai-taskbar-fb-\(UUID().uuidString)"
        addItem(service: service, account: "justoeu", token: "direct")
        let exe = try fake.script("printf '%s\\n' '\(claudeJSON(token: "tool"))'")
        let reader = KeychainCredentialReader(
            service: service, searchList: [keychain.reference],
            fallback: SecurityToolCredentialReader(executable: exe, timeout: 5))
        #expect(try reader.read().accessToken == "direct")
        #expect(reader.canPersistCredentials)
    }

    /// End to end against the real `/usr/bin/security`: an item the *tool*
    /// created (so the tool, not this test process, is its trusted app) is
    /// readable through the fallback with no dialog. Mirrors the production
    /// relationship with the Claude Code CLI's item exactly.
    @Test("the real security tool reads an item it created in a temporary keychain")
    func real_tool_reads_own_item() throws {
        let service = "ai-taskbar-real-\(UUID().uuidString)"
        let payload = claudeJSON(token: "real-tool")
        try runSecurity(["unlock-keychain", "-p", keychain.password, keychain.path])
        try runSecurity(["add-generic-password", "-s", service, "-a", "justoeu", "-w", payload, keychain.path])

        let fallback = SecurityToolCredentialReader(timeout: 10)
        let data = try fallback.read(service: service, account: "justoeu", keychainPaths: [keychain.path])
        #expect(String(decoding: data, as: UTF8.self) == payload)

        // No paths on the instance: the reader must hand over the item's keychain.
        let reader = KeychainCredentialReader(service: service, searchList: [keychain.reference],
                                              fallback: fallback)
        #expect(try reader.read().accessToken == "real-tool")
    }

    private func runSecurity(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = SecurityToolCredentialReader.defaultExecutable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
