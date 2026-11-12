import Foundation

/// Version of the installed Claude Code CLI, read from where its installers
/// put it — never by running the binary.
///
/// Why it matters: Anthropic reveals and honours limit resets only for the
/// Claude Code CLI surface at a recent version. Measured 2026-11-12 against
/// `GET /api/oauth/usage?cedar_ember=1`: `claude-cli/1.0 (external, cli)`
/// is refused as `cli_version`, any other client name as `surface`, and
/// `claude-cli/2.1.322 (external, cli)` is eligible. The reset calls therefore
/// present the version the user actually has installed (decision recorded in
/// `docs/SDD-claude-limit-reset.md`). Nothing installed → nil → no reset.
public enum ClaudeCLIVersion {
    /// `MAJOR.MINOR.PATCH`, digits only: the value goes into an HTTP header.
    public static func isValid(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            (1...6).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// The User-Agent Claude Code sends for this version.
    public static func userAgent(version: String) -> String? {
        isValid(version) ? "claude-cli/\(version) (external, cli)" : nil
    }

    /// First hit wins: the native installer's launcher symlink, the newest of
    /// its versions folder, a Homebrew cask, then an npm global install.
    public static func installed(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        prefixes: [String] = ["/opt/homebrew", "/usr/local"]
    ) -> String? {
        let launcher = home.appendingPathComponent(".local/bin/claude")
        let target = launcher.resolvingSymlinksInPath().lastPathComponent
        if target != launcher.lastPathComponent, isValid(target) { return target }
        if let newest = newest(in: home.appendingPathComponent(".local/share/claude/versions")) {
            return newest
        }
        for prefix in prefixes {
            if let cask = newest(in: URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom/claude-code")) {
                return cask
            }
            let manifest = URL(fileURLWithPath: prefix)
                .appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code/package.json")
            if let version = packageVersion(manifest) { return version }
        }
        return nil
    }

    static func newest(in directory: URL) -> String? {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            return nil // absent install location: the normal case for most of them
        }
        return names.filter(isValid).max { Semver.isNewer($1, than: $0) }
    }

    private struct Manifest: Decodable { let version: String? }

    static let maximumManifestBytes = 256 * 1024

    /// Best-effort probe (an absent or odd manifest just means "not this
    /// install"). Regular files only, and the cap is enforced on the bytes
    /// actually read, not on a size checked beforehand.
    static func packageVersion(_ url: URL) -> String? {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumManifestBytes + 1),
              data.count <= maximumManifestBytes,
              let version = (try? JSONDecoder().decode(Manifest.self, from: data))?.version,
              isValid(version) else { return nil }
        return version
    }
}
