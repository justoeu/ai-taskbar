import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("Paths helpers")
struct PathsTests {
    @Test("applicationSupport returns a real directory")
    func application_support_returns_directory() throws {
        let dir = try Paths.applicationSupport()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test("caches dir is created with 0o700")
    func caches_dir_user_only() throws {
        let dir = try Paths.caches()
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o700)
    }

    @Test("cacheDir(for:) namespaces by vendor")
    func cacheDir_namespaced() throws {
        let a = try Paths.cacheDir(for: .anthropic)
        let b = try Paths.cacheDir(for: .openai)
        #expect(a != b)
        #expect(a.lastPathComponent == "anthropic")
        #expect(b.lastPathComponent == "openai")
    }

    @Test("configFile is application_support/config.toml")
    func config_file_is_known_path() throws {
        let file = try Paths.configFile()
        #expect(file.lastPathComponent == "config.toml")
    }

    @Test("defaultCodexAuth points at ~/.codex/auth.json")
    func default_codex_auth_path() {
        let url = Paths.defaultCodexAuth()
        #expect(url.path.hasSuffix(".codex/auth.json"))
    }

    @Test("ensureDir is idempotent on existing dirs")
    func ensureDir_idempotent() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-paths-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
        try Paths.ensureDir(tmp)  // should not throw
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("ensureDir throws when target is a regular file, not a dir")
    func ensureDir_throws_on_regular_file() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-paths-file-\(UUID().uuidString)")
        try Data("hi".utf8).write(to: tmp)
        do {
            try Paths.ensureDir(tmp)
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .io = err {} else {
                Issue.record("expected .io, got \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("isSymbolicLink returns true for a symlink target")
    func is_symbolic_link_detects_symlink() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-paths-sym-\(UUID().uuidString)")
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-paths-target-\(UUID().uuidString)")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: tmp, withDestinationURL: target)
        #expect(Paths.isSymbolicLink(at: tmp))
        #expect(!Paths.isSymbolicLink(at: target))
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.removeItem(at: target)
    }

    @Test("ensureDir rejects symlinked path (TOCTOU defense)")
    func ensureDir_rejects_symlink_path() throws {
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-paths-symtgt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sym = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-paths-symlnk-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: sym, withDestinationURL: target)
        do {
            try Paths.ensureDir(sym)
            Issue.record("expected throw for symlinked path")
        } catch let err as AppError {
            if case .io = err {} else {
                Issue.record("expected .io, got \(err)")
            }
        } catch {
            Issue.record("expected AppError")
        }
        try? FileManager.default.removeItem(at: sym)
        try? FileManager.default.removeItem(at: target)
    }
}
