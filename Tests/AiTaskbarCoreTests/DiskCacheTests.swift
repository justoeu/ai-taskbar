import XCTest
@testable import AiTaskbarCore

final class DiskCacheTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-tests-\(UUID().uuidString)")
        try Paths.ensureDir(tmp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_write_then_read_within_ttl_returns_fresh_payload() throws {
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp, ttl: 60)
        try cache.writePayload(Data("hello".utf8))
        let data = cache.freshPayload()
        XCTAssertEqual(data, Data("hello".utf8))
        XCTAssertFalse(cache.isStale())
    }

    func test_expired_ttl_returns_nil_but_anyPayload_still_works() throws {
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp,
                              ttl: 0.001, maxStale: 7 * 86_400)
        try cache.writePayload(Data("hi".utf8))
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNil(cache.freshPayload())
        XCTAssertEqual(cache.anyPayload(), Data("hi".utf8))
    }

    func test_markStale_writes_lastError_and_can_read_back() throws {
        let cache = DiskCache(vendor: .anthropic, baseDir: tmp)
        cache.markStale(error: FetchError(status: 429, body: "rate limited"))
        XCTAssertTrue(cache.isStale())
        let err = cache.lastError()
        XCTAssertEqual(err?.status, 429)
        XCTAssertEqual(err?.body, "rate limited")
    }
}
