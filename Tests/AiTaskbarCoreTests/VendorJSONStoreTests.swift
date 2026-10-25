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

    @Test("directory(_:) is created under Application Support")
    func directory_is_created() throws {
        let url = try VendorJSONStore<Probe>.directory("credits")
        #expect(url.lastPathComponent == "credits")
        expectTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
