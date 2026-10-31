import Foundation
import os.lock

/// One `Codable` value per vendor, persisted as
/// `~/Library/Application Support/ai-taskbar/<directory>/<vendor>.json`.
///
/// The shared infrastructure behind `CreditBaselineStore` and
/// `LastSeenWindowStore`, which carried it as two copies that had already
/// drifted (one remembered a missing file and logged write failures, the
/// other did neither). Domain rules stay in those stores; this type owns the
/// cache, the lock and the I/O (`docs/SDD-vendor-json-store.md`).
///
/// Best-effort by design: a value lost to a disk error costs a re-seeded
/// reading, never a wrong number, so failures are logged and never fail the
/// vendor's fetch. NOT for secrets: there is no `0o600` of its own (the
/// parent directory is `0700`); sealed values belong in `MetaTokenStore` /
/// `SecretBox`.
public final class VendorJSONStore<Value: Codable & Sendable & Equatable>: Sendable {
    public let vendor: VendorId
    public let baseDir: URL

    /// `.loaded(nil)` remembers "nothing stored" (absent, or present but not
    /// a valid `Value`) too: this app is the only writer, so a miss stays a
    /// miss until `update`. A file that exists but cannot be READ is never
    /// cached — see `read()`.
    private enum LoadState: Sendable { case unloaded, loaded(Value?) }
    private let cached = OSAllocatedUnfairLock(initialState: LoadState.unloaded)
    /// Serializes every read-modify-write and `clear`. A plain mutex, not the
    /// unfair lock, because it is held across file I/O.
    private let writeGate = NSLock()
    /// Test seam: called with the operation ("read", "persist", "remove")
    /// next to every logged failure, so tests can prove none is swallowed.
    private let onFailure: (@Sendable (String) -> Void)?

    public init(vendor: VendorId, baseDir: URL) {
        self.vendor = vendor
        self.baseDir = baseDir
        self.onFailure = nil
    }

    internal init(vendor: VendorId, baseDir: URL,
                  onFailure: @escaping @Sendable (String) -> Void) {
        self.vendor = vendor
        self.baseDir = baseDir
        self.onFailure = onFailure
    }

    public var fileURL: URL {
        baseDir.appendingPathComponent("\(vendor.rawValue).json")
    }

    /// The stored value. Reads the disk once; an absent file, or one that is
    /// not a valid `Value` (including values `Value`'s own decoder rejects),
    /// reads as nil. A file that exists but cannot be read also reads as nil
    /// this time, but is retried on the next call.
    public func load() -> Value? {
        if case .loaded(let hit) = cached.withLock({ $0 }) { return hit }
        guard case .read(let decoded) = read() else { return nil }
        // The read ran outside the lock: an `update` or `clear` that landed
        // meanwhile is newer than what was read, and must win (a late read
        // would otherwise resurrect a value `clear` removed at logout).
        return cached.withLock { state -> Value? in
            if case .loaded(let newer) = state { return newer }
            state = .loaded(decoded)
            return decoded
        }
    }

    /// The only write path: loads the current value, asks `body` for the
    /// value to store (`nil` = store nothing) and a result, and writes when
    /// it differs from the current one — all under one lock, so overlapping
    /// updates never interleave (RACE-CRO-007). Memory is updated before the
    /// disk, so an unwritable directory still keeps the value this session.
    /// When the file exists but cannot be read, `body` still runs (with nil)
    /// for its result, but NOTHING is written: the real value on disk is
    /// unknown, and replacing it would destroy it (a credits peak re-seeded
    /// from a 90%-spent balance).
    /// `body` runs under the (non-recursive) write lock: it may call `load()`,
    /// but never `update` or `clear` on the same store — that deadlocks.
    @discardableResult
    public func update<R>(_ body: (_ current: Value?) -> (write: Value?, result: R)) -> R {
        writeGate.lock()
        defer { writeGate.unlock() }
        let current: Value?
        let known: Bool
        if case .loaded(let hit) = cached.withLock({ $0 }) {
            (current, known) = (hit, true)
        } else if case .read(let decoded) = read() {
            cached.withLock { $0 = .loaded(decoded) }
            (current, known) = (decoded, true)
        } else {
            (current, known) = (nil, false)
        }
        let (write, result) = body(current)
        if known, let write, write != current {
            save(write)
        }
        return result
    }

    /// Forgets the value in memory and on disk. Waits for an in-flight
    /// `update`, so a "Recalibrate" is never reverted by a late write.
    public func clear() {
        writeGate.lock()
        defer { writeGate.unlock() }
        cached.withLock { $0 = .loaded(nil) }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Nothing stored: already clear.
        } catch {
            report("remove", error)
        }
    }

    private enum ReadOutcome { case read(Value?), unreadable }

    /// Absent → `.read(nil)`; present but not a valid `Value` → `.read(nil)`
    /// (re-seeded, never trusted); present but unreadable (permissions, I/O)
    /// → `.unreadable`, logged, so a transient failure neither caches a miss
    /// nor lets `update` overwrite the real value.
    private func read() -> ReadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch where Self.isAbsence(error) {
            return .read(nil)
        } catch {
            report("read", error)
            return .unreadable
        }
        return .read(try? SharedCoders.decoder.decode(Value.self, from: data))
    }

    /// The file does not exist: no such file, or a path component that is
    /// not a directory (ENOTDIR — nothing can exist below it). Everything
    /// else (permissions, I/O) means a value may be there and is unknown.
    static func isAbsence(_ error: Error) -> Bool { FileAbsence.isAbsence(error) }

    private func save(_ value: Value) {
        cached.withLock { $0 = .loaded(value) }
        do {
            let data = try SharedCoders.encoder.encode(value)
            try AtomicFileWrite.write(data, to: fileURL)
        } catch {
            report("persist", error)
        }
    }

    private func report(_ operation: String, _ error: Error) {
        AppLog.lifecycle.warning(
            "\(self.baseDir.lastPathComponent, privacy: .public)/\(self.fileURL.lastPathComponent, privacy: .public): could not \(operation, privacy: .public): \(String(describing: error), privacy: .public)")
        onFailure?(operation)
    }
}

/// Whether a file-read error means the file does not exist: no such file, or
/// a path component that is not a directory (ENOTDIR — nothing can exist
/// below it). Everything else (permissions, I/O) means it may be there.
enum FileAbsence {
    static func isAbsence(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError,
           cocoa.code == .fileReadNoSuchFile || cocoa.code == .fileNoSuchFile {
            return true
        }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        guard let posix = underlying, posix.domain == NSPOSIXErrorDomain else { return false }
        return posix.code == Int(ENOENT) || posix.code == Int(ENOTDIR)
    }
}
