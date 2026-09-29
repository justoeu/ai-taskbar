import Foundation
import Testing
import AiTaskbarCore
@testable import AiTaskbarApp

/// Serves canned responses keyed by `host + path`; unknown URLs fail with
/// `notConnectedToInternet`, so nothing ever reaches the real network.
/// Process-wide state, so the suite below is `.serialized`.
private final class RouteProtocol: URLProtocol {
    struct Route {
        var status = 200
        var body = Data()
        var redirect: URL?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var routes: [String: Route] = [:]
    private nonisolated(unsafe) static var seen: [URL] = []

    static func set(_ newRoutes: [String: Route]) {
        lock.lock(); defer { lock.unlock() }
        routes = newRoutes
        seen = []
    }

    static var requested: [URL] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.seen.append(url)
        let route = Self.routes["\(url.host ?? "")\(url.path)"]
        Self.lock.unlock()
        guard let route else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if let redirect = route.redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": redirect.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect),
                                redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("UpdateChecker release fetch (BP-REP-003, BUG-ART-014)", .serialized)
@MainActor
final class UpdateCheckerFetchTests {
    private static let sha = String(repeating: "ab", count: 32)
    private static let latestKey = "api.github.com/repos/o/r/releases/latest"
    private static let listKey = "api.github.com/repos/o/r/releases"
    private static let checksumsKey = "github.com/o/r/releases/download/v9.9.9/checksums-9.9.9.txt"

    private let defaultsSuite = "test-updates-fetch-\(UUID().uuidString)"

    deinit {
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        RouteProtocol.set([:])
    }

    private func makeChecker(prereleases: Bool = false) -> UpdateChecker {
        UpdateChecker(
            config: UpdatesConfig(enabled: true, ownerRepo: "o/r", includePrereleases: prereleases),
            currentVersion: "1.0.0",
            http: .stubbed(protocols: [RouteProtocol.self]),
            userDefaults: UserDefaults(suiteName: defaultsSuite)!,
            downloadsDirectory: FileManager.default.temporaryDirectory,
            revealInFinder: { _ in },
            dmgVerifier: TeamSignatureDMGVerifier(teamID: nil))
    }

    private static func releaseJSON(tag: String, prerelease: Bool = false,
                                    draft: Bool = false, withAssets: Bool = true) -> String {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = withAssets ? """
            [{"name":"ai-taskbar-\(version).dmg","size":10,
              "browser_download_url":"https://github.com/o/r/releases/download/\(tag)/ai-taskbar-\(version).dmg"},
             {"name":"ai-taskbar-\(version)-arm64.dmg","size":10,
              "browser_download_url":"https://github.com/o/r/releases/download/\(tag)/ai-taskbar-\(version)-arm64.dmg"},
             {"name":"checksums-\(version).txt","size":10,
              "browser_download_url":"https://github.com/o/r/releases/download/\(tag)/checksums-\(version).txt"}]
            """ : "[]"
        return """
            {"tag_name":"\(tag)","html_url":"https://github.com/o/r/releases/tag/\(tag)",
             "prerelease":\(prerelease),"draft":\(draft),"published_at":null,"assets":\(assets)}
            """
    }

    private static func checksumsBody() -> Data {
        Data("""
            \(sha)  ai-taskbar-9.9.9.dmg
            \(sha)  ai-taskbar-9.9.9-arm64.dmg

            """.utf8)
    }

    private func settle(_ checker: UpdateChecker) async -> UpdateChecker.Status {
        for _ in 0..<500 {
            if case .checking = checker.status {
                try? await Task.sleep(nanoseconds: 10_000_000) // polling; cancellation irrelevant
            } else { break }
        }
        return checker.status
    }

    private func available(_ status: UpdateChecker.Status) -> UpdateChecker.Release? {
        if case .updateAvailable(let release) = status { return release }
        return nil
    }

    private func failed(_ status: UpdateChecker.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    // MARK: BP-REP-003 — bounded reads

    @Test("a releases API body over the cap fails instead of being buffered")
    func oversized_release_json_fails() async {
        var body = Data(Self.releaseJSON(tag: "v9.9.9", withAssets: false).utf8)
        body.append(Data(repeating: 0x20, count: UpdateChecker.maxReleaseResponseBytes))
        RouteProtocol.set([Self.latestKey: .init(body: body)])
        let checker = makeChecker()
        checker.check()
        let status = await settle(checker)
        #expect(failed(status))
    }

    @Test("a checksums body over the cap yields no checksum")
    func oversized_checksums_dropped() async {
        var sums = Self.checksumsBody()
        sums.append(Data(repeating: 0x0A, count: UpdateChecker.maxChecksumsResponseBytes))
        RouteProtocol.set([Self.latestKey: .init(body: Data(Self.releaseJSON(tag: "v9.9.9").utf8)),
                           Self.checksumsKey: .init(body: sums)])
        let checker = makeChecker()
        checker.check()
        let release = available(await settle(checker))
        expectTrue(release != nil)
        expectTrue(release?.dmgSHA256 == nil)
    }

    @Test("checksums redirected to GitHub's asset CDN are still read")
    func checksums_redirect_to_cdn_followed() async {
        let cdn = URL(string: "https://release-assets.githubusercontent.com/o/r/checksums-9.9.9.txt")!
        RouteProtocol.set([Self.latestKey: .init(body: Data(Self.releaseJSON(tag: "v9.9.9").utf8)),
                           Self.checksumsKey: .init(redirect: cdn),
                           "release-assets.githubusercontent.com/o/r/checksums-9.9.9.txt":
                               .init(body: Self.checksumsBody())])
        let checker = makeChecker()
        checker.check()
        let release = available(await settle(checker))
        #expect(release?.dmgSHA256 == Self.sha)
    }

    @Test("checksums redirected off GitHub are refused before the target is requested")
    func checksums_redirect_off_github_refused() async {
        let hostile = URL(string: "https://attacker.example/checksums.txt")!
        RouteProtocol.set([Self.latestKey: .init(body: Data(Self.releaseJSON(tag: "v9.9.9").utf8)),
                           Self.checksumsKey: .init(redirect: hostile),
                           "attacker.example/checksums.txt": .init(body: Self.checksumsBody())])
        let checker = makeChecker()
        checker.check()
        let release = available(await settle(checker))
        expectTrue(release?.dmgSHA256 == nil)
        #expect(!RouteProtocol.requested.contains(hostile))
    }

    // MARK: BUG-ART-014 — include_prereleases

    @Test("opting in to prereleases queries the release list and offers the newest beta")
    func prerelease_opt_in_offers_newest_beta() async {
        let list = "[" + [Self.releaseJSON(tag: "v1.2.0-beta9", prerelease: true, withAssets: false),
                          Self.releaseJSON(tag: "v1.2.0-beta10", prerelease: true, withAssets: false),
                          Self.releaseJSON(tag: "v1.1.0", withAssets: false)].joined(separator: ",") + "]"
        RouteProtocol.set([Self.latestKey: .init(body: Data(Self.releaseJSON(tag: "v1.1.0",
                                                                             withAssets: false).utf8)),
                           Self.listKey: .init(body: Data(list.utf8))])
        let checker = makeChecker(prereleases: true)
        checker.check()
        let release = available(await settle(checker))
        #expect(release?.tag == "v1.2.0-beta10")
    }

    @Test("opting in asks for the release list, not /releases/latest")
    func prerelease_opt_in_path() async {
        RouteProtocol.set([Self.listKey: .init(body: Data("[]".utf8))])
        let checker = makeChecker(prereleases: true)
        checker.check()
        _ = await settle(checker)
        #expect(RouteProtocol.requested.map(\.path) == ["/repos/o/r/releases"])
    }

    @Test("without the opt-in only /releases/latest is queried")
    func stable_only_uses_latest() async {
        RouteProtocol.set([Self.latestKey: .init(body: Data(Self.releaseJSON(tag: "v1.1.0",
                                                                             withAssets: false).utf8))])
        let checker = makeChecker()
        checker.check()
        let release = available(await settle(checker))
        #expect(release?.tag == "v1.1.0")
        #expect(RouteProtocol.requested.map(\.path) == ["/repos/o/r/releases/latest"])
    }

    @Test("drafts in the release list are never offered")
    func prerelease_list_skips_drafts() async {
        let list = "[" + [Self.releaseJSON(tag: "v2.0.0", draft: true, withAssets: false),
                          Self.releaseJSON(tag: "v1.2.0-rc.1", prerelease: true, withAssets: false)]
            .joined(separator: ",") + "]"
        RouteProtocol.set([Self.listKey: .init(body: Data(list.utf8))])
        let checker = makeChecker(prereleases: true)
        checker.check()
        let release = available(await settle(checker))
        #expect(release?.tag == "v1.2.0-rc.1")
    }

    @Test("a stable release beats its own prereleases in the list")
    func stable_beats_own_prerelease_in_list() async {
        let list = "[" + [Self.releaseJSON(tag: "v1.2.0-beta1", prerelease: true, withAssets: false),
                          Self.releaseJSON(tag: "v1.2.0", withAssets: false)].joined(separator: ",") + "]"
        RouteProtocol.set([Self.listKey: .init(body: Data(list.utf8))])
        let checker = makeChecker(prereleases: true)
        checker.check()
        let release = available(await settle(checker))
        #expect(release?.tag == "v1.2.0")
    }

    @Test("an empty release list is reported, not treated as up to date")
    func empty_release_list_fails() async {
        RouteProtocol.set([Self.listKey: .init(body: Data("[]".utf8))])
        let checker = makeChecker(prereleases: true)
        checker.check()
        #expect(failed(await settle(checker)))
    }
}
