import Foundation
import Testing
@testable import AiTaskbarCore
@testable import AiTaskbarApp

/// CQ-MAE-007: at launch `ensureAllVendorSections` ran through `try?`, so a
/// refused write (a symlinked config.toml) left new vendor sections missing
/// with no trace anywhere.
@MainActor
@Suite("Launch config top-up")
struct ConfigTopUpTests {
    private static func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-topup-\(UUID().uuidString)")
        try Paths.ensureDir(dir)
        return dir
    }

    @Test("a refused top-up write (symlinked config.toml) is reported")
    func symlinked_config_failure_is_reported() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("dotfiles-config.toml")
        try Data("[ui]\n".utf8).write(to: target)
        let link = dir.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        var reported = 0
        AppEnvironment.topUpConfigSections(ConfigLoader(path: link), onFailure: { _ in reported += 1 })
        #expect(reported == 1)
    }

    @Test("a successful top-up reports nothing and appends the missing sections")
    func regular_config_is_topped_up() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.toml")
        try Data("[ui]\n".utf8).write(to: file)

        var reported = 0
        AppEnvironment.topUpConfigSections(ConfigLoader(path: file), onFailure: { _ in reported += 1 })
        #expect(reported == 0)
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("[anthropic]"))
    }
}
