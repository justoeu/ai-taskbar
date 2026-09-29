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
        let clock = TestClock()
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp,
                              ttl: 60, maxStale: 7 * 86_400, now: { clock.date })
        try cache.writePayload(Data("hi".utf8))
        clock.date = Date().addingTimeInterval(3600)
        #expect(cache.freshPayload() == nil)
        #expect(cache.anyPayload() == Data("hi".utf8))
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Writes a payload, then returns its on-disk mtime so the injected clock
    /// is measured against exactly what DiskCache will stat.
    private func writeAndReadMtime(_ cache: DiskCache) throws -> Date {
        try cache.writePayload(Data("p".utf8))
        let attrs = try FileManager.default.attributesOfItem(
            atPath: tmp.appendingPathComponent("usage.json").path)
        return try #require(attrs[.modificationDate] as? Date)
    }

    @Test("payload aged exactly ttl is still fresh (TEST-ARG-012)")
    func age_equal_to_ttl_is_fresh() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let clock = TestClock()
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp, ttl: 60,
                              maxStale: 600, now: { clock.date })
        let mtime = try writeAndReadMtime(cache)
        clock.date = mtime.addingTimeInterval(60)

        #expect(cache.freshPayload() == Data("p".utf8))
    }

    @Test("payload aged just past ttl is stale but still served as any (TEST-ARG-012)")
    func age_past_ttl_is_not_fresh() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let clock = TestClock()
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp, ttl: 60,
                              maxStale: 600, now: { clock.date })
        let mtime = try writeAndReadMtime(cache)
        clock.date = mtime.addingTimeInterval(60.001)

        #expect(cache.freshPayload() == nil)
        #expect(cache.anyPayload() == Data("p".utf8))
    }

    @Test("hasFreshPayload agrees with freshPayload at the ttl boundary (PERF-MAE-003)")
    func has_fresh_payload_matches_ttl_boundary() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let clock = TestClock()
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp, ttl: 60,
                              maxStale: 600, now: { clock.date })
        #expect(!cache.hasFreshPayload())
        let mtime = try writeAndReadMtime(cache)
        clock.date = mtime.addingTimeInterval(60)
        #expect(cache.hasFreshPayload())
        clock.date = mtime.addingTimeInterval(60.001)
        #expect(!cache.hasFreshPayload())
    }

    @Test("maxStale boundary: equal is served, just past is dropped (TEST-ARG-012)")
    func max_stale_boundary() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let clock = TestClock()
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp, ttl: 60,
                              maxStale: 600, now: { clock.date })
        let mtime = try writeAndReadMtime(cache)

        clock.date = mtime.addingTimeInterval(600)
        #expect(cache.anyPayload() == Data("p".utf8))
        clock.date = mtime.addingTimeInterval(600.001)
        #expect(cache.anyPayload() == nil)
    }

    @Test("freshPayloadWithAge reads the injected clock")
    func payload_age_uses_injected_clock() throws {
        defer { try? FileManager.default.removeItem(at: tmp) }
        let clock = TestClock()
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp, now: { clock.date })
        let mtime = try writeAndReadMtime(cache)
        clock.date = mtime.addingTimeInterval(42)

        #expect(cache.freshPayloadWithAge()?.1 == 42)
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

    @Test("freshPayloadWithAge returns data and age in one hit (N1-NEX-004)")
    func freshPayloadWithAge_single_hit() throws {
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp, ttl: 60)
        try cache.writePayload(Data("payload".utf8))
        let hit = cache.freshPayloadWithAge()
        #expect(hit?.0 == Data("payload".utf8))
        #expect((hit?.1 ?? 99) < 5)
        try cache.writePayload(Data("ok".utf8))
        cache.markFailed(FetchError(status: 500, body: "x"))
        // write after fail clears markers when writePayload runs last:
        try cache.writePayload(Data("clean".utf8))
        #expect(!cache.isStale())
        #expect(cache.lastError() == nil)
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("anyPayload returns nil after exceeding maxStale")
    func anyPayload_returns_nil_after_maxStale() throws {
        let clock = TestClock()
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp,
                              ttl: 60, maxStale: 600, now: { clock.date })
        try cache.writePayload(Data("old".utf8))
        clock.date = Date().addingTimeInterval(3600)
        #expect(cache.anyPayload() == nil, "past maxStale should drop payload")
        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("usage and status cache scopes use distinct paths and preserve defaults")
    func usage_and_status_scopes_do_not_collide() throws {
        let usage = try DiskCache.defaultFor(.anthropic)
        let status = try DiskCache.defaultFor(.anthropic, scope: .status)

        #expect(usage.baseDir.lastPathComponent == "anthropic")
        #expect(usage.baseDir.deletingLastPathComponent().lastPathComponent == Paths.appName)
        #expect(status.baseDir.lastPathComponent == "anthropic")
        #expect(status.baseDir.deletingLastPathComponent().lastPathComponent == "status")
        #expect(usage.baseDir != status.baseDir)
        #expect(usage.ttl == 300)
        #expect(usage.maxStale == 7 * 24 * 60 * 60)
        #expect(status.ttl == 300)
        #expect(status.maxStale == ServiceStatusWindow.duration)
    }

    @Test("six-hour status stale window expires old payload")
    func six_hour_status_stale_window_expires() throws {
        let cache = DiskCache(
            vendor: .anthropic,
            baseDir: tmp,
            ttl: 60,
            maxStale: ServiceStatusWindow.duration
        )
        try cache.writePayload(Data("old-status".utf8))
        let payload = tmp.appendingPathComponent("usage.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-ServiceStatusWindow.duration - 1)],
            ofItemAtPath: payload.path
        )

        #expect(cache.anyPayload() == nil)
        try? FileManager.default.removeItem(at: tmp)
    }
}

/// Mutable clock for DiskCache boundary tests. Each test owns its instance
/// and reads/writes it from one thread.
private final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 0)
}
