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
        /// Optional SHA-256 hex from a sibling `checksums-*.txt` asset.
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

    @Published public private(set) var status: Status = .idle

    public let config: UpdatesConfig
    public let currentVersion: String
    private let http: HTTPClient

    public init(config: UpdatesConfig,
                currentVersion: String? = nil,
                http: HTTPClient = .init()) {
        self.config = config
        self.currentVersion = currentVersion ?? Self.bundleVersion()
        self.http = http
    }

    public static func bundleVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0-dev"
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
        let endpoint = "https://api.github.com/repos/\(config.ownerRepo)/releases/latest"
        guard let url = URL(string: endpoint) else {
            throw AppError.other(L10n.localizedString("updates_bad_repo"))
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ai-taskbar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.send(req)
        guard (200..<300).contains(response.statusCode) else {
            throw AppError.http(status: response.statusCode,
                                body: String(data: data.prefix(512), encoding: .utf8) ?? "")
        }
        do {
            let raw = try SharedCoders.decoder.decode(GitHubRelease.self, from: data)
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
                dmgSHA = try? await self.fetchChecksum(for: dmgName, from: cURL)
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
        status = .downloading(progress: 0, latest: release)
        // Drop the DMG in ~/Downloads (NOT the system temp dir) so the user
        // can find it later from Finder's sidebar. Falls back to temp if the
        // Downloads directory can't be resolved (rare — sandbox edge case).
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory,
                                                    in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dest = downloadsDir.appendingPathComponent("ai-taskbar-\(release.tag).dmg")
        try? FileManager.default.removeItem(at: dest)

        Task { [weak self] in
            guard let self else { return }
            do {
                // Route through the injected HTTPClient (pinned/ephemeral),
                // never URLSession.shared (ARCH-ATL-001 / SEC-SEN-002).
                var req = URLRequest(url: dmgURL)
                req.setValue("ai-taskbar/\(self.currentVersion)",
                             forHTTPHeaderField: "User-Agent")
                let (tmp, http) = try await self.http.download(req)
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
                if let want = release.dmgSHA256?.lowercased(), !want.isEmpty {
                    let got = try Self.sha256Hex(ofFileAt: tmp)
                    guard got == want else {
                        throw AppError.other("DMG checksum mismatch")
                    }
                }
                try FileManager.default.moveItem(at: tmp, to: dest)
                self.status = .downloaded(localURL: dest, latest: release)
                // Reveal the DMG in Finder so the user can drag the new app
                // into /Applications. We deliberately do NOT auto-open the
                // DMG (no `NSWorkspace.shared.open(dest)`) — a mounted image
                // is one double-click away from executing whatever app the
                // release contained, and a release compromise should not get
                // that far without an explicit user gesture. The user
                // double-clicking in Finder gives Gatekeeper a chance to
                // surface its warning before anything runs.
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                self.status = .failed(message: error.localizedDescription)
            }
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
        let (data, response) = try await http.send(req)
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
}

// MARK: - Wire types for GitHub Releases v3

private struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let prerelease: Bool
    let published_at: String?
    let assets: [Asset]
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int
    }
}
