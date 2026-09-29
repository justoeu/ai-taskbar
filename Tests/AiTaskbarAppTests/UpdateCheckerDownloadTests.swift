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

/// Always answers 404 with a body, so URLSession still hands back a
/// downloaded temp file that `download(_:)` must delete. Immutable.
private final class NotFoundDMGProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 404,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("Not Found".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Answers every non-evil request with a 302 to an off-platform host, and
/// that host with the genuine DMG bytes (so SHA256 and size still match).
/// Records the hosts it was asked for; the suite is `.serialized`.
private final class OffPlatformRedirectDMGProtocol: URLProtocol {
    static let evil = URL(string: "https://evil.example/payload.dmg")!
    private static let lock = NSLock()
    private nonisolated(unsafe) static var hostsStorage: [String] = []
    static var requestedHosts: [String] { lock.withLock { hostsStorage } }
    static func reset() { lock.withLock { hostsStorage = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self.hostsStorage.append(url.host ?? "") }
        if url.host == Self.evil.host {
            let response = HTTPURLResponse(url: url, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: FixedDMGProtocol.body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": Self.evil.absoluteString])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: Self.evil),
                            redirectResponse: redirect)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// URLSession download temp files currently in this process's temp dir.
/// URLSession names them `CFNetworkDownload_*.tmp`.
private func urlSessionDownloadTemps() throws -> Set<String> {
    let names = try FileManager.default.contentsOfDirectory(
        atPath: FileManager.default.temporaryDirectory.path)
    return Set(names.filter { $0.hasPrefix("CFNetworkDownload_") })
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
final class UpdateCheckerDownloadTests {
    private static let bodySHA = SHA256.hash(data: FixedDMGProtocol.body)
        .map { String(format: "%02x", $0) }.joined()

    /// One downloads directory and one UserDefaults suite per test instance,
    /// both removed in `deinit` so repeated runs leave nothing behind.
    private let dir: URL
    private let defaultsSuite = "test-updates-dl-\(UUID().uuidString)"

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir) // test cleanup
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
    }

    private func makeChecker(dir: URL, verifier: StubVerifier,
                             serving proto: AnyClass = FixedDMGProtocol.self) -> UpdateChecker {
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        return UpdateChecker(
            config: UpdatesConfig(enabled: true, ownerRepo: "o/r", includePrereleases: false),
            currentVersion: "1.0.0",
            http: .stubbed(protocols: [proto]),
            userDefaults: defaults,
            downloadsDirectory: dir,
            revealInFinder: { _ in },
            dmgVerifier: verifier)
    }

    private func release(sha: String?,
                         size: Int64 = Int64(FixedDMGProtocol.body.count)) -> UpdateChecker.Release {
        UpdateChecker.Release(
            tag: "v9.9.9",
            htmlURL: URL(string: "https://github.com/o/r/releases/tag/v9.9.9")!,
            prerelease: false, publishedAt: nil,
            dmgURL: URL(string: "https://github.com/o/r/releases/download/v9.9.9/ai-taskbar-9.9.9.dmg")!,
            dmgSize: size,
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
        let checker = makeChecker(dir: dir, verifier: StubVerifier(accept: true))
        checker.download(release(sha: nil))
        let status = await settle(checker)
        expectTrue(isFailed(status))
        expectFalse(FileManager.default.fileExists(atPath: dest(in: dir).path))
    }

    @Test("verified DMG carries the com.apple.quarantine xattr")
    func downloaded_dmg_is_quarantined() async throws {
        let checker = makeChecker(dir: dir, verifier: StubVerifier(accept: true))
        checker.download(release(sha: Self.bodySHA))
        let status = await settle(checker)
        expectTrue(isDownloaded(status))
        let len = getxattr(dest(in: dir).path, "com.apple.quarantine", nil, 0, 0, 0)
        #expect(len > 0)
    }

    @Test("team-signature verifier rejection fails and leaves no file")
    func verifier_rejects() async throws {
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
        let verifier = StubVerifier(accept: true)
        let checker = makeChecker(dir: dir, verifier: verifier)
        checker.download(release(sha: Self.bodySHA))
        let status = await settle(checker)
        expectTrue(isDownloaded(status))
        #expect(verifier.calls.count == 1)
    }

    @Test("quarantine on a missing file throws instead of being swallowed")
    func quarantine_failure_throws() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).dmg")
        #expect(throws: POSIXError.self) {
            try UpdateChecker.applyQuarantine(to: url)
        }
    }

    @Test("checksum mismatch fails and leaves no file")
    func checksum_mismatch() async throws {
        let checker = makeChecker(dir: dir, verifier: StubVerifier(accept: true))
        checker.download(release(sha: String(repeating: "0", count: 64)))
        let status = await settle(checker)
        expectTrue(isFailed(status))
        expectFalse(FileManager.default.fileExists(atPath: dest(in: dir).path))
    }
    // LEAK-FAN-004: every failure after URLSession handed back its temp file
    // must delete that file. Only NEW temp files count (the dir is shared).

    @Test("non-2xx DMG response leaves no URLSession temp file")
    func http_status_failure_removes_temp() async throws {
        let before = try urlSessionDownloadTemps()
        let checker = makeChecker(dir: dir, verifier: StubVerifier(accept: true),
                                  serving: NotFoundDMGProtocol.self)
        checker.download(release(sha: Self.bodySHA))
        let status = await settle(checker)
        expectTrue(isFailed(status))
        #expect(try urlSessionDownloadTemps().subtracting(before) == [])
    }

    @Test("size mismatch leaves no URLSession temp file")
    func size_mismatch_removes_temp() async throws {
        let before = try urlSessionDownloadTemps()
        let checker = makeChecker(dir: dir, verifier: StubVerifier(accept: true))
        checker.download(release(sha: Self.bodySHA, size: 1))
        let status = await settle(checker)
        expectTrue(isFailed(status))
        #expect(try urlSessionDownloadTemps().subtracting(before) == [])
    }

    @Test("checksum mismatch leaves no URLSession temp file")
    func checksum_mismatch_removes_temp() async throws {
        let before = try urlSessionDownloadTemps()
        let checker = makeChecker(dir: dir, verifier: StubVerifier(accept: true))
        checker.download(release(sha: String(repeating: "0", count: 64)))
        let status = await settle(checker)
        expectTrue(isFailed(status))
        #expect(try urlSessionDownloadTemps().subtracting(before) == [])
    }

    @Test("signature rejection leaves no URLSession temp file")
    func signature_rejection_removes_temp() async throws {
        let before = try urlSessionDownloadTemps()
        let checker = makeChecker(dir: dir, verifier: StubVerifier(accept: false))
        checker.download(release(sha: Self.bodySHA))
        let status = await settle(checker)
        expectTrue(isFailed(status))
        #expect(try urlSessionDownloadTemps().subtracting(before) == [])
    }

    /// SEC-MAE-001: the asset URL was checked against the GitHub allow-list,
    /// but URLSession then followed ANY redirect. SHA256 + team signature
    /// still guard the bytes; the redirect itself must not leave GitHub.
    @Test("a DMG redirect off the GitHub allow-list is refused before the target is requested")
    func off_platform_redirect_is_refused() async throws {
        OffPlatformRedirectDMGProtocol.reset()
        let checker = makeChecker(dir: dir, verifier: StubVerifier(accept: true),
                                  serving: OffPlatformRedirectDMGProtocol.self)
        checker.download(release(sha: Self.bodySHA))
        let status = await settle(checker)
        expectTrue(isFailed(status))
        expectFalse(FileManager.default.fileExists(atPath: dest(in: dir).path))
        #expect(!OffPlatformRedirectDMGProtocol.requestedHosts.contains("evil.example"))
    }
}

@Suite("TeamSignatureDMGVerifier")
struct TeamSignatureDMGVerifierTests {
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

/// Scripted `hdiutil`: the attach step is replaced by `attach`, every call is
/// recorded, and detach always succeeds. Only touches the temp root the
/// verifier itself created.
private final class FakeHdiutil: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String]] = []
    private let attach: @Sendable (_ mountRoot: URL) throws -> Data

    init(attach: @escaping @Sendable (_ mountRoot: URL) throws -> Data) {
        self.attach = attach
    }

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return log }
    var detachTargets: [String] { calls.filter { $0.first == "detach" }.map { $0[1] } }

    func run(_ args: [String], _ timeout: TimeInterval) throws -> Data {
        lock.lock(); log.append(args); lock.unlock()
        guard args.first == "attach",
              let i = args.firstIndex(of: "-mountrandom") else { return Data() }
        return try attach(URL(fileURLWithPath: args[i + 1], isDirectory: true))
    }

    static func plist(_ entities: [[String: String]]) -> Data {
        // Fixed-shape test input: serialization of string dictionaries cannot fail.
        (try? PropertyListSerialization.data(fromPropertyList: ["system-entities": entities],
                                             format: .xml, options: 0)) ?? Data()
    }
}

// BP-MAE-001: an attach that mounted something must always be detached.
@Suite("TeamSignatureDMGVerifier detach on failure")
struct TeamSignatureDMGVerifierDetachTests {
    private let dmg = URL(fileURLWithPath: "/nonexistent/x.dmg")

    @Test("attach plist without a mount point detaches the device it attached")
    func no_mount_point_detaches_device() {
        let fake = FakeHdiutil { _ in
            FakeHdiutil.plist([["dev-entry": "/dev/disk9"], ["dev-entry": "/dev/disk9s1"]])
        }
        #expect(throws: TeamSignatureDMGVerifier.Failure.mountFailed) {
            try TeamSignatureDMGVerifier.verifyBlocking(dmg: dmg, teamID: "5HHL78743R",
                                                        timeout: 5, run: fake.run)
        }
        #expect(fake.detachTargets == ["/dev/disk9"])
    }

    @Test("attach killed after mounting detaches what it left under the mount root")
    func timed_out_attach_detaches_leftover_mount() throws {
        let fake = FakeHdiutil { root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("dmg.AbC123"), withIntermediateDirectories: true)
            throw TeamSignatureDMGVerifier.Failure.timedOut
        }
        #expect(throws: TeamSignatureDMGVerifier.Failure.timedOut) {
            try TeamSignatureDMGVerifier.verifyBlocking(dmg: dmg, teamID: "5HHL78743R",
                                                        timeout: 5, run: fake.run)
        }
        #expect(fake.detachTargets.map { URL(fileURLWithPath: $0).lastPathComponent } == ["dmg.AbC123"])
    }

    @Test("attach that failed before mounting anything runs no detach")
    func failed_attach_without_mount_detaches_nothing() {
        let fake = FakeHdiutil { _ in throw TeamSignatureDMGVerifier.Failure.hdiutilExited(1) }
        #expect(throws: TeamSignatureDMGVerifier.Failure.hdiutilExited(1)) {
            try TeamSignatureDMGVerifier.verifyBlocking(dmg: dmg, teamID: "5HHL78743R",
                                                        timeout: 5, run: fake.run)
        }
        #expect(fake.detachTargets == [])
    }

    @Test("a mounted image is detached by its mount point after the check")
    func mounted_image_detached_by_mount_point() throws {
        let fake = FakeHdiutil { root in
            let mount = root.appendingPathComponent("dmg.XyZ")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            return FakeHdiutil.plist([["dev-entry": "/dev/disk9"],
                                      ["dev-entry": "/dev/disk9s1", "mount-point": mount.path]])
        }
        #expect(throws: TeamSignatureDMGVerifier.Failure.noSingleApp) {
            try TeamSignatureDMGVerifier.verifyBlocking(dmg: dmg, teamID: "5HHL78743R",
                                                        timeout: 5, run: fake.run)
        }
        #expect(fake.detachTargets.map { URL(fileURLWithPath: $0).lastPathComponent } == ["dmg.XyZ"])
    }
}
