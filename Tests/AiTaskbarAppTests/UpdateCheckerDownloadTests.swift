import Foundation
import Testing
import CryptoKit
import AiTaskbarCore
@testable import AiTaskbarApp

/// Serves the same fixed "DMG" body for every request. Immutable, so no
/// shared mutable state — the suite is still `.serialized` by convention.
private final class FixedDMGProtocol: URLProtocol {
    static let body = Data("not-really-a-dmg-but-bytes-are-bytes".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct StubVerifier: DMGVerifying {
    struct Rejected: Error {}
    let accept: Bool
    let calls = CallCounter()
    func verify(dmgAt url: URL) async throws {
        calls.increment()
        if !accept { throw Rejected() }
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite("UpdateChecker DMG download verification (SEC-CER-001)", .serialized)
@MainActor
struct UpdateCheckerDownloadTests {
    private static let bodySHA = SHA256.hash(data: FixedDMGProtocol.body)
        .map { String(format: "%02x", $0) }.joined()

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeChecker(dir: URL, verifier: StubVerifier) -> UpdateChecker {
        let name = "test-updates-dl-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return UpdateChecker(
            config: UpdatesConfig(enabled: true, ownerRepo: "o/r", includePrereleases: false),
            currentVersion: "1.0.0",
            http: .stubbed(protocols: [FixedDMGProtocol.self]),
            userDefaults: defaults,
            downloadsDirectory: dir,
            revealInFinder: { _ in },
            dmgVerifier: verifier)
    }

    private func release(sha: String?) -> UpdateChecker.Release {
        UpdateChecker.Release(
            tag: "v9.9.9",
            htmlURL: URL(string: "https://github.com/o/r/releases/tag/v9.9.9")!,
            prerelease: false, publishedAt: nil,
            dmgURL: URL(string: "https://github.com/o/r/releases/download/v9.9.9/ai-taskbar-9.9.9.dmg")!,
            dmgSize: Int64(FixedDMGProtocol.body.count),
            dmgSHA256: sha)
    }

    /// Waits for the download Task to leave `.downloading`.
    private func settle(_ checker: UpdateChecker) async -> UpdateChecker.Status {
        for _ in 0..<500 {
            if case .downloading = checker.status {
                try? await Task.sleep(nanoseconds: 10_000_000) // polling; cancellation irrelevant
            } else { break }
        }
        return checker.status
    }

    private func isFailed(_ s: UpdateChecker.Status) -> Bool {
        if case .failed = s { return true }
        return false
    }

    private func isDownloaded(_ s: UpdateChecker.Status) -> Bool {
        if case .downloaded = s { return true }
        return false
    }

    private func dest(in dir: URL) -> URL { dir.appendingPathComponent("ai-taskbar-v9.9.9.dmg") }

    @Test("release without a parseable checksum fails closed")
    func missing_checksum_fails_closed() async throws {
        let dir = try makeDir()
        let checker = makeChecker(dir: dir, verifier: StubVerifier(accept: true))
        checker.download(release(sha: nil))
        let status = await settle(checker)
        expectTrue(isFailed(status))
        expectFalse(FileManager.default.fileExists(atPath: dest(in: dir).path))
    }

    @Test("verified DMG carries the com.apple.quarantine xattr")
    func downloaded_dmg_is_quarantined() async throws {
        let dir = try makeDir()
        let checker = makeChecker(dir: dir, verifier: StubVerifier(accept: true))
        checker.download(release(sha: Self.bodySHA))
        let status = await settle(checker)
        expectTrue(isDownloaded(status))
        let len = getxattr(dest(in: dir).path, "com.apple.quarantine", nil, 0, 0, 0)
        #expect(len > 0)
    }

    @Test("team-signature verifier rejection fails and leaves no file")
    func verifier_rejects() async throws {
        let dir = try makeDir()
        let verifier = StubVerifier(accept: false)
        let checker = makeChecker(dir: dir, verifier: verifier)
        checker.download(release(sha: Self.bodySHA))
        let status = await settle(checker)
        expectTrue(isFailed(status))
        expectFalse(FileManager.default.fileExists(atPath: dest(in: dir).path))
        #expect(verifier.calls.count == 1)
    }

    @Test("team-signature verifier acceptance downloads")
    func verifier_accepts() async throws {
        let dir = try makeDir()
        let verifier = StubVerifier(accept: true)
        let checker = makeChecker(dir: dir, verifier: verifier)
        checker.download(release(sha: Self.bodySHA))
        let status = await settle(checker)
        expectTrue(isDownloaded(status))
        #expect(verifier.calls.count == 1)
    }

    @Test("checksum mismatch fails and leaves no file")
    func checksum_mismatch() async throws {
        let dir = try makeDir()
        let checker = makeChecker(dir: dir, verifier: StubVerifier(accept: true))
        checker.download(release(sha: String(repeating: "0", count: 64)))
        let status = await settle(checker)
        expectTrue(isFailed(status))
        expectFalse(FileManager.default.fileExists(atPath: dest(in: dir).path))
    }
}

@Suite("TeamSignatureDMGVerifier")
struct TeamSignatureDMGVerifierTests {
    @Test("quarantine on a missing file throws instead of being swallowed")
    func quarantine_failure_throws() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).dmg")
        #expect(throws: POSIXError.self) {
            try UpdateChecker.applyQuarantine(to: url)
        }
    }

    @Test("ad-hoc build (no team) skips the check")
    func nil_team_skips() async throws {
        let url = URL(fileURLWithPath: "/nonexistent/x.dmg")
        try await TeamSignatureDMGVerifier(teamID: nil).verify(dmgAt: url)
    }

    @Test("malformed team ID is rejected before any requirement is built")
    func malformed_team() async {
        let url = URL(fileURLWithPath: "/nonexistent/x.dmg")
        await #expect(throws: TeamSignatureDMGVerifier.Failure.invalidTeamID) {
            try await TeamSignatureDMGVerifier(teamID: "5HHL\" or true").verify(dmgAt: url)
        }
    }

    @Test("team ID shape")
    func team_shape() {
        #expect(TeamSignatureDMGVerifier.isWellFormedTeamID("5HHL78743R"))
        #expect(!TeamSignatureDMGVerifier.isWellFormedTeamID("5hhl78743r"))
        #expect(!TeamSignatureDMGVerifier.isWellFormedTeamID("5HHL7874"))
    }

    @Test("a non-DMG file fails to mount, reported as hdiutil's non-zero exit")
    func garbage_dmg_fails() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).dmg")
        try Data("garbage".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) } // test cleanup
        let error = await #expect(throws: TeamSignatureDMGVerifier.Failure.self) {
            try await TeamSignatureDMGVerifier(teamID: "5HHL78743R", timeout: 20).verify(dmgAt: url)
        }
        guard case .hdiutilExited(let status) = error else {
            Issue.record("expected hdiutilExited, got \(String(describing: error))")
            return
        }
        #expect(status != 0)
    }

    @Test("an Apple app does not satisfy a third-party team requirement")
    func apple_app_wrong_team() {
        let app = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        #expect(throws: TeamSignatureDMGVerifier.Failure.self) {
            try TeamSignatureDMGVerifier.checkSignature(of: app, teamID: "5HHL78743R")
        }
    }

    @Test("attach plist yields the mount point")
    func parses_mount_point() throws {
        let plist: [String: Any] = ["system-entities": [["dev-entry": "/dev/disk9"],
                                                        ["mount-point": "/tmp/x/dmg.abc"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(try TeamSignatureDMGVerifier.mountPoint(fromAttachPlist: data) == "/tmp/x/dmg.abc")
        let empty = try PropertyListSerialization.data(fromPropertyList: ["system-entities": []],
                                                       format: .xml, options: 0)
        #expect(throws: TeamSignatureDMGVerifier.Failure.mountFailed) {
            try TeamSignatureDMGVerifier.mountPoint(fromAttachPlist: empty)
        }
    }
}
