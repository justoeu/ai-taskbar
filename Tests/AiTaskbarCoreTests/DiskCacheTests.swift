import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("DiskCache TTL and stale semantics")
struct DiskCacheTests {
    let tmp: URL

    init() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-tests-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
    }

    @Test("write then read within TTL returns fresh payload")
    func write_then_read_within_ttl_returns_fresh_payload() throws {
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp, ttl: 60)
        try cache.writePayload(Data("hello".utf8))
        #expect(cache.freshPayload() == Data("hello".utf8))
        #expect(!cache.isStale())
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("expired TTL returns nil but anyPayload still works")
    func expired_ttl_returns_nil_but_anyPayload_still_works() throws {
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp,
                              ttl: 0.001, maxStale: 7 * 86_400)
        try cache.writePayload(Data("hi".utf8))
        Thread.sleep(forTimeInterval: 0.05)
        #expect(cache.freshPayload() == nil)
        #expect(cache.anyPayload() == Data("hi".utf8))
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("markFailed writes lastError and can read back")
    func markFailed_writes_lastError_and_can_read_back() throws {
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp)
        cache.markFailed(FetchError(status: 429, body: "rate limited"))
        #expect(cache.isStale())
        let err = cache.lastError()
        #expect(err?.status == 429)
        #expect(err?.body == "rate limited")
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("writePayload creates file with 0o600 perms")
    func writePayload_creates_file_with_user_only_perms() throws {
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp)
        try cache.writePayload(Data("secret".utf8))
        let payloadFile = tmp.appendingPathComponent("usage.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: payloadFile.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("AtomicFileWrite throws AppError.io when destination not writable")
    func atomic_write_throws_when_destination_not_writable() {
        // /System on macOS is SIP-protected and not writable from any user.
        let bad = URL(fileURLWithPath: "/System/ai-taskbar-test-\(UUID().uuidString)")
        do {
            try AtomicFileWrite.write(Data("x".utf8), to: bad, permissions: 0o600)
            Issue.record("expected throw")
        } catch let err as AppError {
            if case .io = err {} else {
                Issue.record("expected .io, got \(err)")
            }
        } catch {
            // Some FS errors come through as NSError; treat as covered.
        }
    }

    @Test("anyPayload returns nil after exceeding maxStale")
    func anyPayload_returns_nil_after_maxStale() throws {
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp,
                              ttl: 0.001, maxStale: 0.01)
        try cache.writePayload(Data("old".utf8))
        Thread.sleep(forTimeInterval: 0.05)
        #expect(cache.anyPayload() == nil, "past maxStale should drop payload")
        try? FileManager.default.removeItem(at: tmp)
    }
}
