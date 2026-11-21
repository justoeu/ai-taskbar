import Foundation
import Testing
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

/// The tests' clock: before both fixture windows reset
/// (`zaiUsageNearLimit200`: 5-hour at 1_795_300_000, weekly at 1_795_900_000).
private let now = Date(timeIntervalSince1970: 1_795_200_000)
private let apiKey = "zai-test-key"

private func credentials(inline: String? = apiKey) -> EnvOrConfigCredentialReader {
    // A variable no environment sets, so only the inline key is read.
    EnvOrConfigCredentialReader(envVarName: "AI_TASKBAR_TEST_UNSET_ZAI_KEY", inlineKey: inline, vendorName: "Z.AI")
}

private func json(_ request: URLRequest) throws -> [String: JSONValue] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
    }
    guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
    return object
}

private func window(_ percent: Double, resetsIn: TimeInterval = 3600) -> UsageWindow {
    UsageWindow(label: "w", utilizationPercent: percent, resetsAt: now.addingTimeInterval(resetsIn))
}

private func grant(_ id: Int64, _ kind: ZAIResetKind, expires: String? = "2026-12-22 23:59:59") -> ZAIResetGrant {
    ZAIResetGrant(recordID: id, kind: kind, grantType: "GLOBAL", expiresAt: expires)
}

// MARK: - Wire types and rule

@Suite("Z.AI quota reset — wire types and rule")
struct ZAIResetWireTests {
    @Test("golden: the measured list decodes to three weekly records")
    func golden() throws {
        let list = try #require(try ZAIResetList.decodeResponse(Fixtures.data(Fixtures.zaiResetList200)))
        #expect(list.fiveHourResets.isEmpty)
        #expect(list.weekResets.count == 3)
        #expect(list.grants == [grant(9, .weekly), grant(10, .weekly), grant(11, .weekly)])
    }

    @Test("a failed list answer reads as no list")
    func failedAnswer() throws {
        #expect(try ZAIResetList.decodeResponse(Data(#"{"code":401,"msg":"x","success":false}"#.utf8)) == nil)
        #expect(try ZAIResetList.decodeResponse(Data(#"{"code":200,"success":false,"data":{}}"#.utf8)) == nil)
        #expect(try ZAIResetList.decodeResponse(Data(#"{"code":200,"success":true}"#.utf8)) == nil)
        #expect(throws: (any Error).self) { try ZAIResetList.decodeResponse(Data("not json".utf8)) }
    }

    @Test("merging keeps the usage payload and drops the account ids")
    func merging() throws {
        let list = try #require(try ZAIResetList.decodeResponse(Fixtures.data(Fixtures.zaiResetList200)))
        let merged = try list.merging(into: Fixtures.data(Fixtures.zaiUsageNearLimit200))
        let text = String(decoding: merged, as: UTF8.self)
        expectFalse(text.contains("customerId"))
        expectFalse(text.contains("12345678901234567"))
        expectFalse(text.contains("organizationId"))
        let snapshot = try JSONDecoder().decode(ZAIEnvelope.self, from: merged).toSnapshot(configTier: nil)
        #expect(snapshot.planLabel == "GLM Max")
        #expect(snapshot.session?.utilizationPercent == 100)
        #expect(snapshot.weekly?.utilizationPercent == 21)
        #expect(snapshot.resetGrants.map(\.recordID) == [9, 10, 11])
        #expect(throws: (any Error).self) { try list.merging(into: Data("[1]".utf8)) }
    }

    @Test("a usage payload without a list has no grants")
    func noList() throws {
        let snapshot = try JSONDecoder().decode(ZAIEnvelope.self, from: Fixtures.data(Fixtures.zaiUsageNearLimit200))
            .toSnapshot(configTier: nil)
        #expect(snapshot.resetGrants.isEmpty)
    }

    @Test("a reshaped list costs only the grants")
    func reshaped() throws {
        var object = try #require({ () -> [String: JSONValue]? in
            guard case .object(let o) = try JSONDecoder().decode(JSONValue.self,
                                                                 from: Fixtures.data(Fixtures.zaiUsageNearLimit200))
            else { return nil }
            return o
        }())
        object[ZAIEnvelope.mergedResetListKey] = .object(["weekResets": .string("nope")])
        let data = try JSONEncoder().encode(JSONValue.object(object))
        let snapshot = try JSONDecoder().decode(ZAIEnvelope.self, from: data).toSnapshot(configTier: nil)
        #expect(snapshot.resetGrants.isEmpty)
        #expect(snapshot.session?.utilizationPercent == 100)
    }

    @Test("a Z.AI field named like ours is never read as the merged list")
    func namespacedKey() throws {
        let usage = Fixtures.zaiUsageNearLimit200.replacingOccurrences(
            of: #""success": true,"#,
            with: #""success": true, "resetList": {"weekResets":[{"recordId":1,"available":true}]},"#)
        let snapshot = try JSONDecoder().decode(ZAIEnvelope.self, from: Data(usage.utf8)).toSnapshot(configTier: nil)
        #expect(snapshot.resetGrants.isEmpty)
        #expect(ZAIEnvelope.mergedResetListKey == "_aiTaskbarResetList")
    }

    @Test("only unused, well-formed records become grants")
    func entryValidation() throws {
        let body = #"""
        {"fiveHourResets":[
          {"recordId":1,"grantType":"GLOBAL","expireTime":"2026-12-01 00:00:00","available":false},
          {"recordId":0,"grantType":"GLOBAL","available":true},
          {"recordId":-3,"available":true},
          {"recordId":2.5,"available":true},
          {"grantType":"GLOBAL","available":true},
          {"recordId":4,"grantType":"BAD TYPE/../","available":true},
          {"recordId":5,"grantType":null,"expireTime":"soon","available":true},
          {"recordId":6,"grantType":"PROMO_1","expireTime":"2026-12-01","available":true},
          {"recordId":7,"grantType":"GLOBAL","expireTime":"2026-12-01 00:00:00"},
          {"recordId":8,"grantType":5,"available":true},
          {"recordId":12,"grantType":"GLOBAL","expireTime":"2026-02-30 00:00:00","available":true}
        ]}
        """#
        let list = try JSONDecoder().decode(ZAIResetList.self, from: Data(body.utf8))
        #expect(list.weekResets.isEmpty)
        #expect(list.grants == [
            ZAIResetGrant(recordID: 5, kind: .fiveHour, grantType: nil, expiresAt: nil),
            ZAIResetGrant(recordID: 6, kind: .fiveHour, grantType: "PROMO_1", expiresAt: "2026-12-01"),
            ZAIResetGrant(recordID: 12, kind: .fiveHour, grantType: "GLOBAL", expiresAt: nil),
        ])
    }

    @Test("grant type and expiry validation")
    func validators() {
        expectTrue(ZAIResetGrant.isValidGrantType("GLOBAL"))
        expectTrue(ZAIResetGrant.isValidGrantType("a-b_C9"))
        expectFalse(ZAIResetGrant.isValidGrantType(""))
        expectFalse(ZAIResetGrant.isValidGrantType("é"))
        expectFalse(ZAIResetGrant.isValidGrantType(String(repeating: "A", count: 33)))
        expectTrue(ZAIResetGrant.isValidExpiry("2026-12-22 23:59:59"))
        expectTrue(ZAIResetGrant.isValidExpiry("2026-12-22"))
        expectFalse(ZAIResetGrant.isValidExpiry("2026-12-22T23:59:59Z"))
        expectFalse(ZAIResetGrant.isValidExpiry("2026-13-45"))
        expectFalse(ZAIResetGrant.isValidExpiry("2026-02-30"))
        expectFalse(ZAIResetGrant.isValidExpiry("2026-12-22 24:00:00"))
        expectFalse(ZAIResetGrant.isValidExpiry("２０２６-12-22"))
        expectTrue(ZAIResetGrant.isValidExpiry("2028-02-29 00:00:00"))
        #expect(grant(1, .weekly).expiryDay == "2026-12-22")
        expectTrue(grant(1, .weekly, expires: nil).expiryDay == nil)
    }

    @Test("a weekly reset is offered for a spent 5-hour window (it refills it too)")
    func weeklyForSession() {
        let snapshot = ZAISnapshot(session: window(100), weekly: window(21, resetsIn: 86_400),
                                   resetGrants: [grant(10, .weekly), grant(9, .weekly, expires: "2026-12-01 00:00:00")])
        let offers = snapshot.limitResetOffers(now: now)
        #expect(offers.map(\.kind) == [.weekly])
        #expect(offers.first?.grant.recordID == 9) // expires first
        #expect(offers.first?.resetsLeft == 2)
        expectTrue(snapshot.hasWindowAboveResetThreshold)
    }

    @Test("a 5-hour reset needs the 5-hour window above 90%")
    func fiveHour() {
        let grants = [grant(1, .fiveHour), grant(2, .weekly)]
        #expect(ZAISnapshot(session: window(95), weekly: window(10), resetGrants: grants)
            .limitResetOffers(now: now).map(\.kind) == [.fiveHour, .weekly])
        #expect(ZAISnapshot(session: window(10), weekly: window(95), resetGrants: grants)
            .limitResetOffers(now: now).map(\.kind) == [.weekly])
        #expect(ZAISnapshot(session: window(10), weekly: window(95), resetGrants: [grant(1, .fiveHour)])
            .limitResetOffers(now: now).isEmpty)
    }

    @Test("exactly 90%, no grants or a window past its reset: no offer")
    func noOffer() {
        let grants = [grant(1, .weekly)]
        #expect(ZAISnapshot(session: window(90), weekly: window(90), resetGrants: grants)
            .limitResetOffers(now: now).isEmpty)
        expectFalse(ZAISnapshot(session: window(90), weekly: window(90)).hasWindowAboveResetThreshold)
        #expect(ZAISnapshot(session: window(100), weekly: window(21)).limitResetOffers(now: now).isEmpty)
        #expect(ZAISnapshot(session: window(100, resetsIn: -1), weekly: window(21), resetGrants: grants)
            .limitResetOffers(now: now).isEmpty)
    }

    @Test("an undated record is spent after the dated ones")
    func undatedLast() {
        let snapshot = ZAISnapshot(session: window(100), resetGrants: [grant(3, .weekly, expires: nil),
                                                                       grant(4, .weekly, expires: "2027-01-01")])
        #expect(snapshot.limitResetOffers(now: now).first?.grant.recordID == 4)
    }

    @Test("snapshot Codable: grants round-trip, older payloads decode")
    func codable() throws {
        let snapshot = ZAISnapshot(planLabel: "GLM Max", session: window(100), resetGrants: [grant(9, .weekly)])
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(ZAISnapshot.self, from: data) == snapshot)
        let old = try JSONDecoder().decode(ZAISnapshot.self, from: Data(#"{"planLabel":"GLM Lite"}"#.utf8))
        #expect(old.resetGrants.isEmpty)
        #expect(old.planLabel == "GLM Lite")
    }
}

// MARK: - Provider

/// A clock the provider reads and the test advances.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = now
    var current: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@Suite("Z.AI provider reads the reset list", .serialized)
struct ZAIProviderResetListTests {
    private let cacheDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zai-reset-\(UUID().uuidString)")
    private let clock = Clock()

    init() { StubURLProtocol.reset() }

    private func provider() -> ZAIProvider {
        let clock = self.clock
        return ZAIProvider(credentials: credentials(), cache: DiskCache(vendor: .zai, baseDir: cacheDir, ttl: 300),
                           http: .stubbed(protocols: [StubURLProtocol.self]), now: { clock.current })
    }

    private func route(usage: String = Fixtures.zaiUsageNearLimit200,
                       list: StubURLProtocol.CannedResponse = .init(data: Fixtures.data(Fixtures.zaiResetList200))) {
        StubURLProtocol.handler = { request in
            request.url?.path == "/api/biz/customer-package-reset/list" ? list : .init(data: Fixtures.data(usage))
        }
    }

    private func grants(_ outcome: FetchOutcome) -> [ZAIResetGrant] {
        guard case .zai(let snapshot) = outcome.snapshot else { return [] }
        return snapshot.resetGrants
    }

    @Test("below 90% the list is never read")
    func belowThreshold() async throws {
        route(usage: Fixtures.zaiUsage200)
        let outcome = try await provider().fetchUsage(forceRefresh: true)
        #expect(grants(outcome).isEmpty)
        #expect(StubURLProtocol.captured.map { $0.url?.path ?? "" } == ["/api/monitor/usage/quota/limit"])
    }

    @Test("above 90% the list is read with the same key and cached allow-listed")
    func aboveThreshold() async throws {
        route()
        let outcome = try await provider().fetchUsage(forceRefresh: true)
        #expect(grants(outcome).map(\.recordID) == [9, 10, 11])
        let captured = StubURLProtocol.captured
        #expect(captured.map { $0.url?.path ?? "" }
            == ["/api/monitor/usage/quota/limit", "/api/biz/customer-package-reset/list"])
        #expect(captured.last?.url?.query == "targetType=PERSONAL")
        expectTrue(captured.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == apiKey })
        expectTrue(captured.allSatisfy { $0.httpMethod == "GET" })
        let cached = try #require(DiskCache(vendor: .zai, baseDir: cacheDir, ttl: 300).anyPayloadWithAge()?.0)
        expectFalse(String(decoding: cached, as: UTF8.self).contains("customerId"))
    }

    @Test("a failed list keeps the numbers and pauses list reads for an hour")
    func failurePauses() async throws {
        route(list: .init(status: 500, data: Data()))
        let p = provider()
        let first = try await p.fetchUsage(forceRefresh: true)
        #expect(grants(first).isEmpty)
        guard case .zai(let snapshot) = first.snapshot else { Issue.record("not zai"); return }
        #expect(snapshot.session?.utilizationPercent == 100)
        StubURLProtocol.reset()
        route()
        _ = try await p.fetchUsage(forceRefresh: true)
        #expect(StubURLProtocol.captured.map { $0.url?.path ?? "" } == ["/api/monitor/usage/quota/limit"])
        // Past the hour the list is read again.
        clock.advance(ZAIProvider.resetListPause + 1)
        StubURLProtocol.reset()
        route()
        #expect(grants(try await p.fetchUsage(forceRefresh: true)).map(\.recordID) == [9, 10, 11])
    }

    @Test("the weekly window alone above 90% reads the list too")
    func weeklyThreshold() async throws {
        route(usage: Fixtures.zaiUsageNearLimit200
            .replacingOccurrences(of: #""percentage": 100"#, with: #""percentage": 10"#)
            .replacingOccurrences(of: #""percentage": 21"#, with: #""percentage": 95"#))
        #expect(grants(try await provider().fetchUsage(forceRefresh: true)).count == 3)
        #expect(StubURLProtocol.captured.count == 2)
    }

    @Test("a usage error keeps its status and never reads the list")
    func usageError() async {
        StubURLProtocol.handler = { _ in .init(status: 401, data: Data("bad key".utf8)) }
        await #expect(throws: (any Error).self) { try await provider().fetchUsage(forceRefresh: true) }
        #expect(StubURLProtocol.captured.count == 1)
    }

    @Test("a list reporting failure in its body pauses too")
    func bodyFailurePauses() async throws {
        route(list: .init(data: Data(#"{"code":401,"msg":"token expired","success":false}"#.utf8)))
        let p = provider()
        #expect(grants(try await p.fetchUsage(forceRefresh: true)).isEmpty)
        StubURLProtocol.reset()
        route()
        _ = try await p.fetchUsage(forceRefresh: true)
        #expect(StubURLProtocol.captured.count == 1)
    }

    @Test("a transport failure on the list keeps the numbers")
    func transportFailure() async throws {
        route(list: .failing(.timedOut))
        let outcome = try await provider().fetchUsage(forceRefresh: true)
        #expect(grants(outcome).isEmpty)
        expectTrue(outcome.lastError == nil)
    }
}

// MARK: - Service

@Suite("Z.AI limit reset service", .serialized)
struct ZAILimitResetServiceTests {
    init() { StubURLProtocol.reset() }

    private func service(key: String? = apiKey) -> ZAILimitResetService {
        ZAILimitResetService(credentials: credentials(inline: key),
                             http: .stubbed(protocols: [StubURLProtocol.self]), now: { now })
    }

    private static var ok: StubURLProtocol.CannedResponse {
        .init(data: Data(#"{"code":200,"msg":"Operation successful","success":true}"#.utf8))
    }

    private func route(use: StubURLProtocol.CannedResponse = ok,
                       usage: String = Fixtures.zaiUsageNearLimit200,
                       list: StubURLProtocol.CannedResponse = .init(data: Fixtures.data(Fixtures.zaiResetList200))) {
        StubURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/biz/customer-package-reset/list": return list
            case "/api/biz/customer-package-reset/use": return use
            default: return .init(data: Fixtures.data(usage))
            }
        }
    }

    private func attempt(recordID: Int64 = 9, grantType: String? = "GLOBAL") -> ZAILimitResetAttempt {
        ZAILimitResetAttempt(kind: .weekly, recordID: recordID, grantType: grantType,
                             expiresAt: "2026-12-22 23:59:59", resetsLeft: 3)
    }

    private var paths: [String] { StubURLProtocol.captured.map { $0.url?.path ?? "" } }

    @Test("prepare re-reads usage and list, spending nothing")
    func prepare() async throws {
        route()
        let attempt = try await service().prepare(kind: .weekly)
        #expect(attempt.kind == .weekly)
        #expect(attempt.recordID == 9)
        #expect(attempt.grantType == "GLOBAL")
        #expect(attempt.expiresAt == "2026-12-22 23:59:59")
        #expect(attempt.resetsLeft == 3)
        #expect(paths == ["/api/monitor/usage/quota/limit", "/api/biz/customer-package-reset/list"])
        expectTrue(StubURLProtocol.captured.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test("prepare without an offer of that kind fails before any use")
    func prepareNoOffer() async {
        route()
        await #expect(throws: ZAILimitResetError.noEligibleReset) { try await service().prepare(kind: .fiveHour) }
        StubURLProtocol.reset()
        route(usage: Fixtures.zaiUsage200)
        await #expect(throws: ZAILimitResetError.noEligibleReset) { try await service().prepare(kind: .weekly) }
        expectFalse(paths.contains("/api/biz/customer-package-reset/use"))
    }

    @Test("no API key: authorization, nothing sent")
    func noKey() async {
        route()
        await #expect(throws: ZAILimitResetError.authorization) { try await service(key: nil).prepare(kind: .weekly) }
        #expect(StubURLProtocol.captured.isEmpty)
    }

    @Test("status failures are definitive")
    func statusFailures() async {
        route(list: .init(status: 401, data: Data()))
        await #expect(throws: ZAILimitResetError.authorization) { try await service().prepare(kind: .weekly) }
        StubURLProtocol.reset()
        route(list: .init(status: 429, data: Data()))
        await #expect(throws: ZAILimitResetError.rateLimited) { try await service().prepare(kind: .weekly) }
        StubURLProtocol.reset()
        route(list: .init(data: Data(#"{"code":500,"success":false}"#.utf8)))
        await #expect(throws: ZAILimitResetError.failed) { try await service().prepare(kind: .weekly) }
        StubURLProtocol.reset()
        route(usage: #"{"code":401,"msg":"bad key","success":false}"#)
        await #expect(throws: ZAILimitResetError.authorization) { try await service().prepare(kind: .weekly) }
        StubURLProtocol.reset()
        route(usage: #"{"code":1001,"msg":"x","success":false}"#)
        await #expect(throws: ZAILimitResetError.failed) { try await service().prepare(kind: .weekly) }
        StubURLProtocol.reset()
        route(list: .failing(.notConnectedToInternet))
        await #expect(throws: ZAILimitResetError.failed) { try await service().prepare(kind: .weekly) }
        StubURLProtocol.reset()
        route(usage: "not json")
        await #expect(throws: ZAILimitResetError.failed) { try await service().prepare(kind: .weekly) }
        StubURLProtocol.reset()
        route(list: .init(status: 404, data: Data()))
        await #expect(throws: ZAILimitResetError.failed) { try await service().prepare(kind: .weekly) }
        // A read that spends nothing is never "uncertain".
        StubURLProtocol.reset()
        route(list: .init(status: 500, data: Data()))
        await #expect(throws: ZAILimitResetError.failed) { try await service().prepare(kind: .weekly) }
        // The list's own body codes map like the usage body's.
        StubURLProtocol.reset()
        route(list: .init(data: Data(#"{"code":401,"msg":"expired","success":false}"#.utf8)))
        await #expect(throws: ZAILimitResetError.authorization) { try await service().prepare(kind: .weekly) }
        StubURLProtocol.reset()
        route(list: .init(data: Data(#"{"code":429,"success":false}"#.utf8)))
        await #expect(throws: ZAILimitResetError.rateLimited) { try await service().prepare(kind: .weekly) }
    }

    @Test("consume re-checks, then POSTs the console's body with the raw key")
    func consume() async throws {
        route()
        let attempt = attempt()
        let receipt = try await service().consume(attempt, retry: false)
        #expect(receipt == ZAILimitResetReceipt(kind: .weekly))
        #expect(paths == ["/api/monitor/usage/quota/limit", "/api/biz/customer-package-reset/list",
                          "/api/biz/customer-package-reset/use"])
        let use = try #require(StubURLProtocol.captured.last)
        #expect(use.httpMethod == "POST")
        #expect(use.value(forHTTPHeaderField: "Authorization") == apiKey)
        let body = try json(use)
        #expect(body["targetType"] == .string("PERSONAL"))
        #expect(body["resetType"] == .string("WEEK"))
        #expect(body["recordId"] == .int(9))
        #expect(body["requestId"] == .string(attempt.requestID))
        #expect(body["grantType"] == .string("GLOBAL"))
        #expect(body.count == 5)
    }

    @Test("a record with no grant type omits it")
    func noGrantType() async throws {
        route()
        _ = try await service().consume(attempt(grantType: nil), retry: true)
        #expect(try json(try #require(StubURLProtocol.captured.last))["grantType"] == nil)
    }

    @Test("a retry sends only the same use, with the same requestId")
    func retry() async throws {
        route()
        let attempt = attempt()
        _ = try await service().consume(attempt, retry: true)
        #expect(paths == ["/api/biz/customer-package-reset/use"])
        #expect(try json(try #require(StubURLProtocol.captured.last))["requestId"] == .string(attempt.requestID))
    }

    @Test("a record gone before the confirmation is never used")
    func recordGone() async {
        route()
        await #expect(throws: ZAILimitResetError.noEligibleReset) {
            try await service().consume(attempt(recordID: 99), retry: false)
        }
        StubURLProtocol.reset()
        route(usage: Fixtures.zaiUsage200)
        await #expect(throws: ZAILimitResetError.noEligibleReset) { try await service().consume(attempt(), retry: false) }
        expectFalse(paths.contains("/api/biz/customer-package-reset/use"))
    }

    @Test("a tampered attempt is never sent")
    func tampered() async {
        route()
        for bad in [attempt(recordID: 0), attempt(grantType: "a b")] {
            StubURLProtocol.reset()
            route()
            await #expect(throws: ZAILimitResetError.failed) { try await service().consume(bad, retry: true) }
            #expect(StubURLProtocol.captured.isEmpty)
        }
    }

    @Test("answers that may have spent the reset are uncertain")
    func uncertain() async {
        let answers: [StubURLProtocol.CannedResponse] = [
            .init(status: 502, data: Data()),
            .failing(.networkConnectionLost),
            .init(data: Data("<html>".utf8)),
            .init(data: Data(#"{"code":500,"msg":"internal","success":false}"#.utf8)),
            .init(data: Data("{}".utf8)),
            .init(data: Data(#"{"msg":"?"}"#.utf8)),
        ]
        for answer in answers {
            StubURLProtocol.reset()
            route(use: answer)
            await #expect(throws: ZAILimitResetError.submissionUncertain) {
                try await service().consume(attempt(), retry: true)
            }
        }
    }

    @Test("a refusal is an answer: nothing spent on a first attempt, unknown on a retry")
    func refusal() async throws {
        for body in [#"{"code":400,"msg":"record used","success":false}"#, #"{"code":200,"success":false}"#] {
            StubURLProtocol.reset()
            route(use: .init(data: Data(body.utf8)))
            #expect(try await service().consume(attempt(), retry: false).outcome == .refused)
            StubURLProtocol.reset()
            route(use: .init(data: Data(body.utf8)))
            #expect(try await service().consume(attempt(), retry: true).outcome == .unconfirmed)
        }
        StubURLProtocol.reset()
        route()
        #expect(try await service().consume(attempt(), retry: true).outcome == .reset)
    }

    @Test("definitive failures")
    func definitive() async {
        let answers: [(StubURLProtocol.CannedResponse, ZAILimitResetError)] = [
            (.init(data: Data(#"{"code":401,"success":false}"#.utf8)), .authorization),
            (.init(data: Data(#"{"code":429,"success":false}"#.utf8)), .rateLimited),
            (.init(status: 403, data: Data()), .authorization),
            (.init(status: 429, data: Data()), .rateLimited),
            (.init(status: 404, data: Data()), .failed),
        ]
        for (answer, expected) in answers {
            StubURLProtocol.reset()
            route(use: answer)
            await #expect(throws: expected) { try await service().consume(attempt(), retry: true) }
        }
    }

    @Test("the provider exposes the service for its own key")
    func providerService() async throws {
        route()
        let p = ZAIProvider(credentials: credentials(),
                            cache: DiskCache(vendor: .zai,
                                             baseDir: FileManager.default.temporaryDirectory
                                                .appendingPathComponent("zai-svc-\(UUID().uuidString)"),
                                             ttl: 300),
                            http: .stubbed(protocols: [StubURLProtocol.self]), now: { now })
        #expect(try await p.limitResets.prepare(kind: .weekly).recordID == 9)
    }
}
