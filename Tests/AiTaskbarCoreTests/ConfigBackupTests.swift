import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("Config backup before a destructive rewrite")
struct ConfigBackupTests {
    private func tempLoader() throws -> (ConfigLoader, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-backup-\(UUID().uuidString)")
        try Paths.ensureDir(dir)
        return (ConfigLoader(path: dir.appendingPathComponent("config.toml")), dir)
    }

    @Test("the backup is a byte-for-byte, user-only copy with a dated name")
    func backup_copy() throws {
        let (loader, dir) = try tempLoader()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("[zai]\napi_key = \"enc:v1:SECRET-MARKER\"\n".utf8)
        try AtomicFileWrite.write(original, to: loader.path, permissions: 0o600)
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let backup = try #require(try loader.backupCurrentFile(now: now))
        #expect(try Data(contentsOf: backup) == original)
        #expect(backup.lastPathComponent.hasPrefix("config.toml.bak-"))
        #expect(backup.deletingLastPathComponent() == loader.path.deletingLastPathComponent())
        let perms = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test("no file, no backup")
    func no_file() throws {
        let (loader, dir) = try tempLoader()
        defer { try? FileManager.default.removeItem(at: dir) }
        expectTrue(try loader.backupCurrentFile() == nil)
    }
}
