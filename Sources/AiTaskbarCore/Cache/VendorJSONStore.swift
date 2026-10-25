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

    /// `.loaded(nil)` remembers "nothing stored" (absent or unreadable) too:
    /// this app is the only writer, so a miss stays a miss until `update`.
    private enum LoadState: Sendable { case unloaded, loaded(Value?) }
    private let cached = OSAllocatedUnfairLock(initialState: LoadState.unloaded)
    /// Serializes every read-modify-write and `clear`. A plain mutex, not the
    /// unfair lock, because it is held across file I/O.
    private let writeGate = NSLock()

    public init(vendor: VendorId, baseDir: URL) {
        self.vendor = vendor
        self.baseDir = baseDir
    }

    /// `Application Support/ai-taskbar/<name>`, created (symlinks refused).
    public static func directory(_ name: String) throws -> URL {
        let dir = try Paths.applicationSupport()
            .appendingPathComponent(name, isDirectory: true)
        try Paths.ensureDir(dir)
        return dir
    }

    public var fileURL: URL {
        baseDir.appendingPathComponent("\(vendor.rawValue).json")
    }

    /// The stored value. Reads the disk once; absent or unreadable files —
    /// including values `Value`'s own decoder rejects — read as nil.
    public func load() -> Value? {
        if case .loaded(let hit) = cached.withLock({ $0 }) { return hit }
        let decoded = (try? Data(contentsOf: fileURL))
            .flatMap { try? SharedCoders.decoder.decode(Value.self, from: $0) }
        cached.withLock { $0 = .loaded(decoded) }
        return decoded
    }

    /// The only write path: loads the current value, asks `body` for the
    /// value to store (`nil` = store nothing) and a result, and writes when
    /// it differs from the current one — all under one lock, so overlapping
    /// updates never interleave (RACE-CRO-007). Memory is updated before the
    /// disk, so an unwritable directory still keeps the value this session.
    @discardableResult
    public func update<R>(_ body: (_ current: Value?) -> (write: Value?, result: R)) -> R {
        writeGate.lock()
        defer { writeGate.unlock() }
        let current = load()
        let (write, result) = body(current)
        if let write, write != current {
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
            AppLog.lifecycle.warning(
                "\(self.fileURL.lastPathComponent, privacy: .public) in \(self.baseDir.lastPathComponent, privacy: .public): could not remove: \(String(describing: error), privacy: .public)")
        }
    }

    private func save(_ value: Value) {
        cached.withLock { $0 = .loaded(value) }
        do {
            let data = try SharedCoders.encoder.encode(value)
            try AtomicFileWrite.write(data, to: fileURL)
        } catch {
            AppLog.lifecycle.warning(
                "\(self.fileURL.lastPathComponent, privacy: .public) in \(self.baseDir.lastPathComponent, privacy: .public): could not persist: \(String(describing: error), privacy: .public)")
        }
    }
}
