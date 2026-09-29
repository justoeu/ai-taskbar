import Foundation

public enum AtomicFileWrite {
    /// Writes `data` to `dest` via a tempfile in the same directory so readers
    /// either see the old contents or the new contents — never a half-written
    /// file.
    ///
    /// When `permissions` is non-nil, the tempfile is **created** with that
    /// mode (`open(2)` + `fchmod` before a single byte is written), so the
    /// payload never sits on disk under the umask default (RACE-CRO-010).
    /// `rename(2)` then swaps the new inode in, so `dest` ends up with the
    /// requested mode even when an older copy had a looser one
    /// (TEST-ARG-001). Pass `0o600` for any file containing secrets.
    ///
    /// When `permissions` is nil, an existing destination keeps its mode and a
    /// new one gets the process default (`0o666 & ~umask`).
    ///
    /// A destination that is a **symlink is refused**: the call throws
    /// `AppError.io` and leaves both the link and its target untouched.
    /// `rename(2)` would otherwise silently replace the link with a regular
    /// file (breaking a dotfile-managed link and leaving the target stale),
    /// and writing through it would let a planted link redirect a secret.
    ///
    /// Because the new inode replaces the old one, extended attributes and
    /// ACLs set on the previous file are not carried over.
    public static func write(_ data: Data, to dest: URL,
                             permissions: Int? = nil) throws {
        try write(data, to: dest, permissions: permissions, tempWritten: nil)
    }

    /// `tempWritten` is a test seam: it runs after the payload is on disk in
    /// the tempfile and before the rename.
    static func write(_ data: Data, to dest: URL, permissions: Int?,
                      tempWritten: ((URL) -> Void)?) throws {
        let dir = dest.deletingLastPathComponent()
        try Paths.ensureDir(dir)
        let existing = lstatMode(of: dest)
        if let existing, existing & S_IFMT == S_IFLNK {
            throw AppError.io("refusing to replace symlinked file \(dest.path)")
        }
        let tmp = dir.appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            let mode = permissions.map { mode_t($0) } ?? existing.map { $0 & 0o7777 }
            try writeTemp(data, to: tmp, mode: mode)
            tempWritten?(tmp)
            guard rename(tmp.path, dest.path) == 0 else { throw posixError("rename") }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw AppError.io("atomic write \(dest.lastPathComponent) failed: \(error)")
        }
    }

    /// `st_mode` (type + permission bits) of the destination itself — `lstat`,
    /// so a symlink is reported as a link — or nil when there is none.
    private static func lstatMode(of dest: URL) -> mode_t? {
        var st = stat()
        guard lstat(dest.path, &st) == 0 else { return nil }
        return st.st_mode
    }

    private static func writeTemp(_ data: Data, to tmp: URL, mode: mode_t?) throws {
        let fd = open(tmp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
                      mode ?? 0o666)
        guard fd >= 0 else { throw posixError("open") }
        defer { close(fd) }
        // open(2) masks the mode with the umask; fchmod makes it exact while
        // the file is still empty.
        if let mode, fchmod(fd, mode) != 0 { throw posixError("fchmod") }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write")
                }
                remaining -= written
                base = base.advanced(by: written)
            }
        }
        guard fsync(fd) == 0 else { throw posixError("fsync") }
    }

    private static func posixError(_ call: String) -> Error {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "\(call): \(String(cString: strerror(code)))"])
    }
}
