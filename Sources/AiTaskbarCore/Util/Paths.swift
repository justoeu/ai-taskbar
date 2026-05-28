import Foundation
import Darwin

public enum Paths {
    public static let appName = "ai-taskbar"

    public static func applicationSupport() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        try ensureDir(dir)
        // Lock down the app's support dir to user-only (0o700) since users
        // may keep `api_key = "..."` in config.toml inside it. macOS umask
        // would otherwise leave it at 0o755.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: dir.path
        )
        return dir
    }

    public static func caches() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        try ensureDir(dir)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: dir.path
        )
        return dir
    }

    public static func cacheDir(for vendor: VendorId) throws -> URL {
        let dir = try caches().appendingPathComponent(vendor.rawValue, isDirectory: true)
        try ensureDir(dir)
        return dir
    }

    public static func configFile() throws -> URL {
        try applicationSupport().appendingPathComponent("config.toml")
    }

    public static func defaultCodexAuth() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex/auth.json")
    }

    public static func ensureDir(_ url: URL) throws {
        // TOCTOU defense: refuse to use a symlinked target. If the user (or
        // an attacker with write to the parent) replaced
        // `~/Library/Application Support/ai-taskbar` with a symlink, we'd
        // happily write credentials elsewhere otherwise. We check via
        // `lstat` so symlink resolution doesn't hide the fact.
        if isSymbolicLink(at: url) {
            throw AppError.io("Refusing to use symlinked path: \(url.path)")
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } else if !isDir.boolValue {
            throw AppError.io("expected directory at \(url.path)")
        }
    }

    /// `lstat`-based symlink check — `attributesOfItem` follows symlinks and
    /// would miss this. macOS-only; we already require Darwin here.
    public static func isSymbolicLink(at url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }
}
