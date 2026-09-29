import Foundation
import SwiftUI
import AppKit
import CryptoKit
import AiTaskbarCore

/// Polls GitHub Releases for a newer tag than the running build's
/// `CFBundleShortVersionString`. When a newer release exists, downloads the
/// universal `.dmg` asset to a temp file and reveals it in Finder so the user
/// can drag the new app into `/Applications`. Fully manual the rest of the
/// way — we never replace the running binary (Gatekeeper without Developer ID
/// + need for helper privileges = too many edge cases).
@MainActor
public final class UpdateChecker: ObservableObject {
    public enum Status: Equatable {
        case idle
        case checking
        case upToDate(currentVersion: String)
        case updateAvailable(latest: Release)
        case downloading(progress: Double, latest: Release)
        case downloaded(localURL: URL, latest: Release)
        case failed(message: String)

        public var isBusy: Bool {
            if case .checking = self { return true }
            if case .downloading = self { return true }
            return false
        }
    }

    public struct Release: Equatable, Sendable {
        public let tag: String
        public let htmlURL: URL
        public let prerelease: Bool
        public let publishedAt: Date?
        public let dmgURL: URL?
        public let dmgSize: Int64?
        /// SHA-256 hex from a sibling `checksums-*.txt` asset. nil means the
        /// release cannot be verified, and `download(_:)` refuses it.
        public let dmgSHA256: String?
    }

    /// Hosts allowed for DMG download (SEC-SEN-002). Release API stays on
    /// api.github.com via `http`; asset bytes must come from GitHub CDNs only.
    nonisolated internal static let allowedDownloadHosts: Set<String> = [
        "github.com",
        "www.github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "github-releases.githubusercontent.com",
    ]

    /// Caps on the buffered GitHub responses (BP-REP-003). A release object
    /// is a few KiB and a `per_page=20` list well under 1 MiB; the checksums
    /// file is two lines. The DMG itself streams to disk via `download`.
    nonisolated internal static let maxReleaseResponseBytes = 2 * 1024 * 1024
    nonisolated internal static let maxChecksumsResponseBytes = 64 * 1024

    nonisolated public static let cadenceInterval: TimeInterval = 86_400 // 24 hours
    nonisolated public static let lastCheckKey: String = "ai_taskbar_last_update_check_at"
    nonisolated public static let dismissedTagKey: String = "ai_taskbar_dismissed_update_tag"

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var dismissedTag: String?

    public let config: UpdatesConfig
    public let currentVersion: String
    public let userDefaults: UserDefaults
    private let http: HTTPClient
    /// Where the DMG lands; nil → the user's ~/Downloads (tests inject a temp dir).
    private let downloadsDirectory: URL?
    private let revealInFinder: @MainActor (URL) -> Void
    private let dmgVerifier: any DMGVerifying

    /// `http` has no default on purpose: the composition root must pass
    /// `env.http`, the pinned client when `pin_hosts` is set (ARCH-ATL-004).
    public init(config: UpdatesConfig,
                currentVersion: String? = nil,
                http: HTTPClient,
                userDefaults: UserDefaults = .standard,
                downloadsDirectory: URL? = nil,
                revealInFinder: @escaping @MainActor (URL) -> Void = {
                    NSWorkspace.shared.activateFileViewerSelecting([$0])
                },
                dmgVerifier: any DMGVerifying = TeamSignatureDMGVerifier()) {
        self.config = config
        self.currentVersion = currentVersion ?? Self.bundleVersion()
        self.http = http
        self.userDefaults = userDefaults
        self.downloadsDirectory = downloadsDirectory
        self.revealInFinder = revealInFinder
        self.dmgVerifier = dmgVerifier
        self.dismissedTag = userDefaults.string(forKey: Self.dismissedTagKey)
    }

    public static func bundleVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0-dev"
    }

    public var lastCheckDate: Date? {
        let ts = userDefaults.double(forKey: Self.lastCheckKey)
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private func recordCheckDate(_ date: Date = Date()) {
        userDefaults.set(date.timeIntervalSince1970, forKey: Self.lastCheckKey)
    }

    public var isUpdateBannerVisible: Bool {
        switch status {
        case .updateAvailable(let release),
             .downloading(_, let release),
             .downloaded(_, let release):
            return dismissedTag != release.tag
        case .idle, .checking, .upToDate, .failed:
            return false
        }
    }

    public func dismissCurrentUpdate() {
        switch status {
        case .updateAvailable(let release),
             .downloading(_, let release),
             .downloaded(_, let release):
            dismissedTag = release.tag
            userDefaults.set(release.tag, forKey: Self.dismissedTagKey)
        case .idle, .checking, .upToDate, .failed:
            break
        }
    }

    public func checkIfNeeded(force: Bool = false) {
        guard config.enabled else { return }
        if status.isBusy { return }
        if !force, let last = lastCheckDate, Date().timeIntervalSince(last) < Self.cadenceInterval {
            return
        }
        check()
    }

    // MARK: - Check

    public func check() {
        guard config.enabled else {
            status = .failed(message: L10n.localizedString("updates_disabled"))
            return
        }
        guard !config.ownerRepo.isEmpty, config.ownerRepo.contains("/") else {
            status = .failed(message: L10n.localizedString("updates_bad_repo"))
            return
        }
        recordCheckDate()
        status = .checking
        Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await self.fetchLatest()
                if Semver.isNewer(release.tag, than: self.currentVersion) {
                    self.status = .updateAvailable(latest: release)
                } else {
                    self.status = .upToDate(currentVersion: self.currentVersion)
                }
            } catch {
                self.status = .failed(message: error.localizedDescription)
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        // /releases/latest never returns a prerelease, so the opt-in has to
        // read the list and pick the newest non-draft itself (BUG-ART-014).
        let path = config.includePrereleases ? "releases?per_page=20" : "releases/latest"
        let endpoint = "https://api.github.com/repos/\(config.ownerRepo)/\(path)"
        guard let url = URL(string: endpoint) else {
            throw AppError.other(L10n.localizedString("updates_bad_repo"))
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ai-taskbar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.sendBounded(
            req, maximumResponseBytes: Self.maxReleaseResponseBytes)
        guard (200..<300).contains(response.statusCode) else {
            throw AppError.http(status: response.statusCode,
                                body: String(data: data.prefix(512), encoding: .utf8) ?? "")
        }
        do {
            let raw: GitHubRelease
            if config.includePrereleases {
                let list = try SharedCoders.decoder.decode([GitHubRelease].self, from: data)
                guard let newest = Self.newestPublished(list) else {
                    throw AppError.other(L10n.localizedString("updates_no_release"))
                }
                raw = newest
            } else {
                raw = try SharedCoders.decoder.decode(GitHubRelease.self, from: data)
            }
            // Skip if it's a pre-release and config says to ignore them.
            if raw.prerelease && !config.includePrereleases {
                throw AppError.other(L10n.localizedString("updates_no_stable"))
            }
            #if arch(arm64)
            let isARM64 = true
            #else
            let isARM64 = false
            #endif
            let pickedName = Self.pickDMGAsset(names: raw.assets.map(\.name),
                                               isARM64: isARM64)
            let asset = raw.assets.first(where: { $0.name == pickedName })
            let dmgURL = asset.flatMap { URL(string: $0.browser_download_url) }
            let checksumsAsset = raw.assets.first {
                $0.name.hasPrefix("checksums-") && $0.name.hasSuffix(".txt")
            }
            var dmgSHA: String?
            if let dmgName = asset?.name,
               let cURL = checksumsAsset.flatMap({ URL(string: $0.browser_download_url) }),
               Self.isAllowedDownloadURL(cURL) {
                do {
                    dmgSHA = try await self.fetchChecksum(for: dmgName, from: cURL)
                } catch {
                    // Not fatal for the CHECK (the update still shows), but
                    // download() fails closed on a nil checksum (SEC-CER-001).
                    AppLog.updates.error("checksum fetch failed: \(String(describing: error), privacy: .public)")
                }
            }
            return Release(
                tag: raw.tag_name,
                htmlURL: URL(string: raw.html_url) ?? URL(string: "about:blank")!,
                prerelease: raw.prerelease,
                publishedAt: Self.parseDate(raw.published_at),
                dmgURL: dmgURL,
                dmgSize: asset.map { Int64($0.size) },
                dmgSHA256: dmgSHA
            )
        } catch let appErr as AppError {
            throw appErr
        } catch {
            throw AppError.schema("decode GitHub release: \(error)")
        }
    }

    /// Newest non-draft release by SemVer precedence, so a stable 1.2.0
    /// beats its own 1.2.0-beta10 regardless of the list's order.
    private static func newestPublished(_ list: [GitHubRelease]) -> GitHubRelease? {
        list.filter { $0.draft != true }.reduce(nil) { best, next in
            guard let best else { return next }
            return Semver.isNewer(next.tag_name, than: best.tag_name) ? next : best
        }
    }

    /// Picks the best DMG asset name for this machine. Since local publishing
    /// (make publish), releases ship two DMGs: `…-arm64.dmg` (Apple
    /// Silicon-only, half the size) and the universal `ai-taskbar-X.Y.Z.dmg`.
    /// Apple Silicon prefers the arch-specific image and falls back to the
    /// universal one (covers old single-DMG releases); Intel only ever takes
    /// the universal — offering an arm64-only DMG there would download a
    /// binary that can't run.
    nonisolated internal static func pickDMGAsset(names: [String],
                                                  isARM64: Bool) -> String? {
        let dmgs = names.filter { $0.hasSuffix(".dmg") }
        let armSpecific = dmgs.first { $0.hasSuffix("-arm64.dmg") }
        let universal = dmgs.first { !$0.hasSuffix("-arm64.dmg") }
        return isARM64 ? (armSpecific ?? universal) : universal
    }

    // MARK: - Download

    public func download(_ release: Release) {
        guard let dmgURL = release.dmgURL else {
            status = .failed(message: L10n.localizedString("updates_no_asset"))
            return
        }
        guard Self.isAllowedDownloadURL(dmgURL) else {
            status = .failed(message: L10n.localizedString("updates_bad_repo"))
            return
        }
        // Fail closed: no checksum from the release's checksums-*.txt means
        // nothing ties these bytes to what was published (SEC-CER-001).
        guard let wantSHA = release.dmgSHA256?.lowercased(), !wantSHA.isEmpty else {
            status = .failed(message: L10n.localizedString("updates_no_checksum"))
            return
        }
        status = .downloading(progress: 0, latest: release)
        // Drop the DMG in ~/Downloads (NOT the system temp dir) so the user
        // can find it later from Finder's sidebar. Falls back to temp if the
        // Downloads directory can't be resolved (rare — sandbox edge case).
        let downloadsDir = downloadsDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dest = downloadsDir.appendingPathComponent("ai-taskbar-\(release.tag).dmg")
        try? FileManager.default.removeItem(at: dest)

        Task { [weak self] in
            guard let self else { return }
            // Whatever is on disk and not yet handed to the user; deleted on
            // every failure path (LEAK-FAN-004).
            var pending: URL?
            do {
                // Route through the injected HTTPClient (pinned/ephemeral),
                // never URLSession.shared (ARCH-ATL-001 / SEC-SEN-002).
                var req = URLRequest(url: dmgURL)
                req.setValue("ai-taskbar/\(self.currentVersion)",
                             forHTTPHeaderField: "User-Agent")
                let (tmp, http) = try await self.http.download(req)
                pending = tmp
                guard (200..<300).contains(http.statusCode) else {
                    throw AppError.http(status: http.statusCode, body: "DMG download")
                }
                if let expected = release.dmgSize, expected > 0 {
                    let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                    if size != expected {
                        throw AppError.other("DMG size mismatch (got \(size), expected \(expected))")
                    }
                }
                guard try Self.sha256Hex(ofFileAt: tmp) == wantSHA else {
                    throw AppError.other("DMG checksum mismatch")
                }
                // Size and checksum come from the same release; anchor trust
                // outside it: the contained .app must be signed by our team.
                do {
                    try await self.dmgVerifier.verify(dmgAt: tmp)
                } catch {
                    AppLog.updates.error("DMG signature check failed: \(String(describing: error), privacy: .public)")
                    throw AppError.other(L10n.localizedString("updates_signature_invalid"))
                }
                try FileManager.default.moveItem(at: tmp, to: dest)
                pending = dest
                // URLSession downloads carry no quarantine, so Gatekeeper
                // would never assess the DMG or the app copied out of it.
                do {
                    try Self.applyQuarantine(to: dest)
                } catch {
                    AppLog.updates.error("quarantine xattr failed: \(String(describing: error), privacy: .public)")
                    throw AppError.other(L10n.localizedString("updates_quarantine_failed"))
                }
                pending = nil
                self.status = .downloaded(localURL: dest, latest: release)
                // Reveal the DMG in Finder so the user can drag the new app
                // into /Applications. We deliberately do NOT auto-open the
                // DMG (no `NSWorkspace.shared.open(dest)`) — a mounted image
                // is one double-click away from executing whatever app the
                // release contained, and a release compromise should not get
                // that far without an explicit user gesture. The user
                // double-clicking in Finder gives Gatekeeper a chance to
                // surface its warning before anything runs.
                self.revealInFinder(dest)
            } catch {
                if let pending {
                    try? FileManager.default.removeItem(at: pending) // best-effort cleanup
                }
                self.status = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Sets `com.apple.quarantine` so Gatekeeper assesses the DMG (and the
    /// app copied out of it) on first open. Throws the POSIX errno on failure.
    nonisolated internal static func applyQuarantine(to url: URL, now: Date = Date()) throws {
        let value = String(format: "0083;%08x;ai-taskbar;%@",
                           UInt32(truncatingIfNeeded: Int(now.timeIntervalSince1970)),
                           UUID().uuidString)
        let rc = value.withCString { ptr in
            setxattr(url.path, "com.apple.quarantine", ptr, strlen(ptr), 0, 0)
        }
        guard rc == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    nonisolated internal static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host?.lowercased() else { return false }
        if allowedDownloadHosts.contains(host) { return true }
        // Allow nested githubusercontent hosts.
        return host.hasSuffix(".githubusercontent.com")
    }

    private func fetchChecksum(for assetName: String, from url: URL) async throws -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("ai-taskbar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        // The asset URL redirects to GitHub's CDN: follow only allow-listed
        // HTTPS hosts, never an arbitrary Location.
        let (data, response) = try await http.sendBounded(
            req, maximumResponseBytes: Self.maxChecksumsResponseBytes,
            allowRedirect: { Self.isAllowedDownloadURL($0) })
        guard (200..<300).contains(response.statusCode),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // Lines: "<sha256>  <filename>" or "<sha256> *filename"
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            let hash = String(parts[0]).lowercased()
            let name = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if name == assetName, hash.count == 64, hash.allSatisfy(\.isHexDigit) {
                return hash
            }
        }
        return nil
    }

    nonisolated internal static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func openReleasePage(_ release: Release) {
        NSWorkspace.shared.open(release.htmlURL)
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return ISO8601Parsing.parse(s)
    }

    #if DEBUG
    internal func setMockStatusForTesting(_ mockStatus: Status) {
        self.status = mockStatus
    }
    #endif
}

// MARK: - Wire types for GitHub Releases v3

private struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let prerelease: Bool
    /// Only present in list responses; `/releases/latest` never has drafts.
    let draft: Bool?
    let published_at: String?
    let assets: [Asset]
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int
    }
}
