import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("Installed Claude Code version")
struct ClaudeCLIVersionTests {
    let home: URL
    let prefix: URL

    init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-cliver-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }

    private func installed() -> String? {
        ClaudeCLIVersion.installed(home: home, prefixes: [prefix.path])
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    @Test("nothing installed → nil")
    func nothing() {
        #expect(installed() == nil)
    }

    @Test("the native launcher's symlink target names the version")
    func launcher() throws {
        let versions = home.appendingPathComponent(".local/share/claude/versions")
        try touch(versions.appendingPathComponent("2.1.300"))
        try touch(versions.appendingPathComponent("2.1.322"))
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("claude"),
                                                   withDestinationURL: versions.appendingPathComponent("2.1.300"))
        #expect(installed() == "2.1.300")
    }

    @Test("without a launcher, the newest versions entry wins numerically")
    func versionsFolder() throws {
        let versions = home.appendingPathComponent(".local/share/claude/versions")
        for name in ["2.1.9", "2.1.10", "notes.txt", "3.0"] {
            try touch(versions.appendingPathComponent(name))
        }
        #expect(installed() == "2.1.10")
    }

    @Test("Homebrew cask and npm installs are read without running anything")
    func packageInstalls() throws {
        let manifest = prefix.appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code/package.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"name":"@anthropic-ai/claude-code","version":"2.0.77"}"#.utf8).write(to: manifest)
        #expect(installed() == "2.0.77")
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("Caskroom/claude-code/2.1.5"), withIntermediateDirectories: true)
        #expect(installed() == "2.1.5")
    }

    @Test("a manifest version that is not plain digits is ignored")
    func badManifest() throws {
        let manifest = prefix.appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code/package.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":"2.0.0\r\nX-Evil: 1"}"#.utf8).write(to: manifest)
        #expect(installed() == nil)
    }

    @Test("validation keeps the header value to digits and dots")
    func validation() {
        expectTrue(ClaudeCLIVersion.isValid("2.1.322"))
        expectFalse(ClaudeCLIVersion.isValid("2.1"))
        expectFalse(ClaudeCLIVersion.isValid("2.1.3-beta"))
        expectFalse(ClaudeCLIVersion.isValid("2.1.3 "))
        expectFalse(ClaudeCLIVersion.isValid("2..3"))
        expectFalse(ClaudeCLIVersion.isValid("1234567.1.1"))
        #expect(ClaudeCLIVersion.userAgent(version: "2.1.322") == "claude-cli/2.1.322 (external, cli)")
        #expect(ClaudeCLIVersion.userAgent(version: "x") == nil)
    }
}
