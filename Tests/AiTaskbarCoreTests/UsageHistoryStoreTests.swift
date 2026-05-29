import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("UsageHistoryStore append/load/compact", .serialized)
struct UsageHistoryStoreTests {
    let tmp: URL

    init() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-hist-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
    }

    @Test("append then load returns the same sample")
    func append_then_load_returns_sample() async throws {
        let store = UsageHistoryStore(vendor: .anthropic, baseDir: tmp)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        store.append(maxUtilization: 45.5, at: when)
        let samples = store.load(since: Date(timeIntervalSince1970: 1_000_000_000))
        #expect(samples.count == 1)
        #expect(samples.first?.max == 45.5)
        #expect(samples.first?.at == 1_700_000_000)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("append creates file with 0o600 perms")
    func append_creates_user_only_file() throws {
        let store = UsageHistoryStore(vendor: .openai, baseDir: tmp)
        store.append(maxUtilization: 10)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("load filters by `since`")
    func load_filters_by_since() async throws {
        let store = UsageHistoryStore(vendor: .zai, baseDir: tmp)
        let old = Date(timeIntervalSince1970: 1_000)
        let mid = Date(timeIntervalSince1970: 5_000)
        let new = Date(timeIntervalSince1970: 9_000)
        store.append(maxUtilization: 10, at: old)
        store.append(maxUtilization: 50, at: mid)
        store.append(maxUtilization: 90, at: new)
        let samples = store.load(since: Date(timeIntervalSince1970: 4_000))
        #expect(samples.count == 2)
        #expect(samples.contains(where: { $0.max == 50 }))
        #expect(samples.contains(where: { $0.max == 90 }))
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("compact trims samples older than retention")
    func compact_trims_old_samples() throws {
        // retention = 1s so anything older than 1s drops.
        let store = UsageHistoryStore(vendor: .openrouter, baseDir: tmp, retention: 1)
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date.now.addingTimeInterval(-0.1)
        store.append(maxUtilization: 10, at: old)
        store.append(maxUtilization: 60, at: recent)
        store.compact()
        let samples = store.load(since: Date(timeIntervalSince1970: 1))
        // Only the recent sample should survive.
        #expect(samples.count == 1)
        #expect(samples.first?.max == 60)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("load returns empty when file does not exist")
    func load_empty_when_no_file() throws {
        let store = UsageHistoryStore(vendor: .kimi, baseDir: tmp)
        let samples = store.load(since: Date(timeIntervalSince1970: 0))
        #expect(samples.isEmpty)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("defaultFor builds a store under the application support dir")
    func defaultFor_builds_store() throws {
        let store = try UsageHistoryStore.defaultFor(.anthropic)
        #expect(store.fileURL.lastPathComponent == "anthropic.jsonl")
        #expect(store.baseDir.path.contains("history"))
    }

    @Test("Sample Codable round-trip")
    func sample_codable_round_trip() throws {
        let s = UsageHistoryStore.Sample(at: 1_700_000_000, max: 42.5)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(UsageHistoryStore.Sample.self, from: data)
        #expect(back == s)
    }
}
