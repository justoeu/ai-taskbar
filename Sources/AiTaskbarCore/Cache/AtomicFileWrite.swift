import Foundation

public enum AtomicFileWrite {
    /// Writes `data` to `dest` via a tempfile in the same directory so readers
    /// either see the old contents or the new contents — never a half-written
    /// file.
    ///
    /// When `permissions` is non-nil, the tempfile is chmod'd to that mode
    /// **before** the rename. This avoids a race where credential payloads
    /// briefly exist on disk as mode 0644 (process umask default) between
    /// the rename and a later chmod. Pass `0o600` for any file containing
    /// secrets.
    public static func write(_ data: Data, to dest: URL,
                             permissions: Int? = nil) throws {
        let dir = dest.deletingLastPathComponent()
        try Paths.ensureDir(dir)
        let tmp = dir.appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if let permissions {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: permissions)],
                    ofItemAtPath: tmp.path
                )
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw AppError.io("atomic write \(dest.lastPathComponent) failed: \(error)")
        }
    }
}
