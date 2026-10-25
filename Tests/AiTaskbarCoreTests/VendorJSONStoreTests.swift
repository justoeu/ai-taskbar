import Testing
import Foundation
@testable import AiTaskbarCore

/// One test per rule of `docs/SDD-vendor-json-store.md` §3.
@Suite("VendorJSONStore", .serialized)
final class VendorJSONStoreTests {
    /// A value whose own decoder rejects a negative `n`, standing in for
    /// `CreditBaseline`'s NaN/negative-peak guard.
    struct Probe: Codable, Sendable, Equatable {
        let n: Int
        init(n: Int) { self.n = n }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try c.decode(Int.self, forKey: .n)
            guard raw >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .n, in: c, debugDescription: "negative")
            }
            n = raw
        }
    }

    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-taskbar-vendorjson-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func store() -> VendorJSONStore<Probe> {
        VendorJSONStore(vendor: .openai, baseDir: dir)
    }

    private func set(_ s: VendorJSONStore<Probe>, _ n: Int) {
        s.update { _ in (write: Probe(n: n), result: ()) }
    }

    @Test("a written value is read back by a new instance, under <vendor>.json")
    func round_trip_across_instances() {
        set(store(), 7)
        #expect(store().load() == Probe(n: 7))
        #expect(store().fileURL.lastPathComponent == "openai.json")
    }

    @Test("a miss is remembered: a file written behind the store is not re-read")
    func miss_is_remembered() {
        let s = store()
        #expect(s.load() == nil)
        set(store(), 3)        // another instance writes the file
        #expect(s.load() == nil)
        #expect(store().load() == Probe(n: 3))
    }

    @Test("corrupt JSON reads as nothing stored")
    func corrupt_reads_as_absent() throws {
        try Data("{not json".utf8).write(to: store().fileURL)
        #expect(store().load() == nil)
    }

    @Test("a value the type's own decoder rejects reads as nothing stored")
    func rejected_value_reads_as_absent() throws {
        try Data(#"{"n":-1}"#.utf8).write(to: store().fileURL)
        #expect(store().load() == nil)
    }

    @Test("update returns the body's result and passes the current value")
    func update_passes_current_and_returns_result() {
        let s = store()
        set(s, 5)
        let seen: Int? = s.update { current in (write: nil, result: current?.n) }
        #expect(seen == 5)
    }

    @Test("an unchanged value is not rewritten")
    func unchanged_value_not_rewritten() throws {
        let s = store()
        set(s, 9)
        let before = try FileManager.default.attributesOfItem(atPath: s.fileURL.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                                              ofItemAtPath: s.fileURL.path)
        set(s, 9)
        let after = try FileManager.default.attributesOfItem(atPath: s.fileURL.path)[.modificationDate] as? Date
        #expect(before != nil)
        #expect(after == Date(timeIntervalSince1970: 0))
    }

    @Test("write nil stores nothing (it is not a delete)")
    func nil_write_stores_nothing() {
        let s = store()
        set(s, 4)
        s.update { _ in (write: nil, result: ()) }
        #expect(s.load() == Probe(n: 4))
        #expect(store().load() == Probe(n: 4))
    }

    @Test("an unwritable directory keeps the value in memory")
    func unwritable_dir_keeps_memory() {
        let s = VendorJSONStore<Probe>(vendor: .openai,
                                       baseDir: URL(fileURLWithPath: "/dev/null/nope-\(UUID().uuidString)"))
        set(s, 11)
        #expect(s.load() == Probe(n: 11))
    }

    @Test("clear forgets memory and disk; clearing nothing is fine")
    func clear_forgets() {
        let s = store()
        set(s, 2)
        s.clear()
        #expect(s.load() == nil)
        expectFalse(FileManager.default.fileExists(atPath: s.fileURL.path))
        s.clear()
        #expect(s.load() == nil)
    }

    @Test("clear waits for a parked update, so the update cannot resurrect the value")
    func clear_waits_for_update() {
        let s = store()
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let updateDone = DispatchSemaphore(value: 0)
        let clearDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            s.update { _ in
                parked.signal()
                release.wait()
                return (write: Probe(n: 1), result: ())
            }
            updateDone.signal()
        }
        parked.wait()
        DispatchQueue.global().async {
            s.clear()
            clearDone.signal()
        }
        let clearedEarly = clearDone.wait(timeout: .now() + 0.3) == .success
        release.signal()
        updateDone.wait()
        if !clearedEarly { clearDone.wait() }
        expectFalse(clearedEarly)
        #expect(s.load() == nil)
        expectFalse(FileManager.default.fileExists(atPath: s.fileURL.path))
    }

    @Test("Paths.supportSubdirectory creates the folder under its root")
    func directory_is_created() throws {
        let url = try Paths.supportSubdirectory("credits", in: dir)
        #expect(url == dir.appendingPathComponent("credits", isDirectory: true))
        var isDir: ObjCBool = false
        expectTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        expectTrue(isDir.boolValue)
    }

    @Test("Paths.supportSubdirectory refuses a symlinked folder")
    func directory_refuses_symlink() throws {
        let target = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("quota"),
                                                   withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try Paths.supportSubdirectory("quota", in: dir)
        }
    }

    // MARK: unreadable ≠ absent, and failures are reported (SDD §3 rules 2, 5)

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var ops: [String] = []
        func add(_ op: String) { lock.withLock { ops.append(op) } }
        var all: [String] { lock.withLock { ops } }
    }

    @Test("a present but unreadable file is never overwritten, and is retried")
    func unreadable_file_is_not_overwritten() throws {
        set(store(), 50)
        let url = store().fileURL
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let failures = Failures()
        let s = VendorJSONStore<Probe>(vendor: .openai, baseDir: dir, onFailure: { failures.add($0) })
        #expect(s.load() == nil)
        let seen: Int? = s.update { current in (write: Probe(n: 5), result: current?.n) }
        #expect(seen == nil)
        #expect(failures.all.contains("read"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        // Not cached as a miss, not replaced: the real value is still there.
        #expect(s.load() == Probe(n: 50))
    }

    @Test("a failed write is reported, not swallowed")
    func failed_write_is_reported() {
        let failures = Failures()
        let s = VendorJSONStore<Probe>(vendor: .openai,
                                       baseDir: URL(fileURLWithPath: "/dev/null/nope-\(UUID().uuidString)"),
                                       onFailure: { failures.add($0) })
        set(s, 1)
        #expect(failures.all == ["persist"])
    }

    @Test("a failed remove is reported, not swallowed")
    func failed_remove_is_reported() throws {
        set(store(), 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let failures = Failures()
        let s = VendorJSONStore<Probe>(vendor: .openai, baseDir: dir, onFailure: { failures.add($0) })
        s.clear()
        #expect(failures.all == ["remove"])
        #expect(s.load() == nil)
    }

    @Test("a missing file and a clear with nothing stored report nothing")
    func absence_is_not_a_failure() {
        let failures = Failures()
        let s = VendorJSONStore<Probe>(vendor: .openai, baseDir: dir, onFailure: { failures.add($0) })
        #expect(s.load() == nil)
        s.clear()
        #expect(failures.all.isEmpty)
    }
}
