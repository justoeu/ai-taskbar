import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders
import AiTaskbarTesting

private final class FixedReader: AnthropicCredentialReading, @unchecked Sendable {
    var credentials = AnthropicCredentials(
        accessToken: "tok", refreshToken: "r",
        expiresAtMs: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
        subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
    var failure: AppError?
    var writeBacks = 0
    func read() throws -> AnthropicCredentials {
        if let failure { throw failure }
        return credentials
    }
    func writeBack(_ updated: AnthropicCredentials) throws { writeBacks += 1 }
}

private let accountUUID = "11111111-2222-3333-4444-555555555555"
private let orgUUID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
private let profileJSON = #"""
{ "account": { "uuid": "11111111-2222-3333-4444-555555555555", "email": "x@example.com", "full_name": "X" },
  "organization": { "uuid": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "name": "X's Org" } }
"""#
/// Inside both grants' validity and before the weekly window resets.
private let now = ISO8601Parsing.parse("2026-11-12T12:00:00Z")!

private func body(of request: URLRequest) -> [String: String] {
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
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
}

private func resetsSnapshot(weekly: Double = 95, fable: Double = 40) throws -> AnthropicSnapshot {
    var json = Fixtures.anthropicUsageWithResets200
    json = json.replacingOccurrences(of: #""utilization": 95.0"#, with: #""utilization": \#(weekly)"#)
    json = json.replacingOccurrences(of: #""percent": 40,"#, with: #""percent": \#(fable),"#)
    return try JSONDecoder().decode(AnthropicUsageResponse.self, from: Fixtures.data(json))
        .toSnapshot(planLabel: nil)
}

// MARK: - Wire + rule

@Suite("Claude limit resets — wire and offer rule")
struct ClaudeLimitResetWireTests {
    @Test("golden: cedar_ember grants decode, next grant first, malformed and paused dropped")
    func golden() throws {
        let snap = try resetsSnapshot()
        #expect(snap.resetGrants.count == 2)
        let weekly = snap.resetGrants[0]
        #expect(weekly.id == "full-reset-2611")
        #expect(weekly.label == "One full limit reset (November 2026)")
        #expect(weekly.kind == .weekly)
        #expect(weekly.resetsLeft == 1)
        #expect(weekly.clears == ["seven_day", "seven_day_overage_included"])
        expectFalse(weekly.givesBackWeekly)
        #expect(weekly.startsAt == ISO8601Parsing.parse("2026-11-10T21:30:00+00:00"))
        #expect(weekly.endsAt == ISO8601Parsing.parse("2026-12-10T22:00:00+00:00"))
        let fable = snap.resetGrants[1]
        #expect(fable.id == "launch-2610-fable")
        #expect(fable.kind == .fable)
        #expect(fable.clears == ["seven_day_overage_included"])
        expectTrue(fable.givesBackWeekly)
        #expect(fable.endsAt == ISO8601Parsing.parse("2027-03-09T07:59:00+00:00"))
    }

    @Test("an ineligible status yields no grants even when it lists some")
    func ineligible() throws {
        let json = Fixtures.anthropicUsageWithResets200
            .replacingOccurrences(of: #""eligible": true"#, with: #""eligible": false"#)
        let snap = try JSONDecoder().decode(AnthropicUsageResponse.self, from: Fixtures.data(json))
            .toSnapshot(planLabel: nil)
        #expect(snap.resetGrants.isEmpty)
    }

    @Test("the plain payload (no cedar_ember) has no grants")
    func plainPayload() throws {
        let snap = try JSONDecoder().decode(AnthropicUsageResponse.self,
                                            from: Fixtures.data(Fixtures.anthropicUsage200))
            .toSnapshot(planLabel: nil)
        #expect(snap.resetGrants.isEmpty)
    }

    @Test("classification follows Claude Code")
    func classification() {
        #expect(ClaudeResetGrant.classify(type: "full", clears: ["seven_day"], givesBackWeekly: true) == .fable)
        #expect(ClaudeResetGrant.classify(type: "weekly", clears: [], givesBackWeekly: false) == .weekly)
        #expect(ClaudeResetGrant.classify(type: "session", clears: ["seven_day"], givesBackWeekly: false) == .session)
        #expect(ClaudeResetGrant.classify(type: nil, clears: ["five_hour"], givesBackWeekly: false) == .session)
        #expect(ClaudeResetGrant.classify(type: nil, clears: ["seven_day"], givesBackWeekly: false) == .weekly)
        #expect(ClaudeResetGrant.classify(type: nil, clears: ["five_hour", "seven_day"], givesBackWeekly: false) == .full)
        #expect(ClaudeResetGrant.classify(type: "fable", clears: ["five_hour"], givesBackWeekly: false) == .session)
    }

    @Test("weekly above 90% offers the weekly and the Fable reset")
    func weeklyOver90() throws {
        let offers = try resetsSnapshot(weekly: 95).limitResetOffers(now: now)
        #expect(offers.map(\.kind) == [.weekly, .fable])
        #expect(offers.first?.grant.id == "full-reset-2611")
        #expect(offers.first?.resetsLeft == 1)
    }

    @Test("exactly 90% offers nothing, like OpenAI")
    func exactly90() throws {
        #expect(try resetsSnapshot(weekly: 90, fable: 90).limitResetOffers(now: now).isEmpty)
    }

    @Test("the Fable window alone above 90% offers both grants that refill it")
    func fableOver90() throws {
        let offers = try resetsSnapshot(weekly: 10, fable: 97).limitResetOffers(now: now)
        #expect(offers.map(\.kind) == [.weekly, .fable])
    }

    @Test("an expired or not-yet-started grant is not offered")
    func grantWindow() throws {
        let snap = try resetsSnapshot()
        let afterWeeklyGrant = ISO8601Parsing.parse("2026-12-11T00:00:00Z")!
        // Windows reset on 2026-11-19, so give them a later reset for this case.
        let later = AnthropicSnapshot(
            weekly: UsageWindow(label: "Weekly (7d)", utilizationPercent: 95,
                                resetsAt: afterWeeklyGrant.addingTimeInterval(86_400)),
            resetGrants: snap.resetGrants)
        #expect(later.limitResetOffers(now: afterWeeklyGrant).map(\.kind) == [.fable])
        let beforeStart = ISO8601Parsing.parse("2026-11-01T00:00:00Z")!
        #expect(snap.limitResetOffers(now: beforeStart).isEmpty)
    }

    @Test("a window already past its reset time is not offered")
    func awaitingReset() throws {
        let afterReset = ISO8601Parsing.parse("2026-11-19T08:00:00Z")!
        #expect(try resetsSnapshot().limitResetOffers(now: afterReset).isEmpty)
    }

    @Test("a session grant follows the 5-hour window")
    func sessionGrant() {
        let grant = ClaudeResetGrant(id: "s", label: "", kind: .session, resetsLeft: 2,
                                     clears: ["five_hour"], givesBackWeekly: false)
        let high = AnthropicSnapshot(session: UsageWindow(label: "Session (5h)", utilizationPercent: 91),
                                     weekly: UsageWindow(label: "Weekly (7d)", utilizationPercent: 10),
                                     resetGrants: [grant])
        #expect(high.limitResetOffers(now: now).map(\.kind) == [.session])
        #expect(high.limitResetOffers(now: now).first?.resetsLeft == 2)
        let low = AnthropicSnapshot(session: UsageWindow(label: "Session (5h)", utilizationPercent: 50),
                                    weekly: UsageWindow(label: "Weekly (7d)", utilizationPercent: 99),
                                    resetGrants: [grant])
        #expect(low.limitResetOffers(now: now).isEmpty)
    }

    @Test("a full grant with no clears list refills any window; NaN never qualifies")
    func fullGrant() {
        let grant = ClaudeResetGrant(id: "f", label: "", kind: .full, resetsLeft: 1,
                                     clears: [], givesBackWeekly: false)
        let opus = AnthropicSnapshot(opus: UsageWindow(label: "Opus (7d)", utilizationPercent: 92),
                                     resetGrants: [grant])
        #expect(opus.limitResetOffers(now: now).map(\.kind) == [.full])
        let nan = AnthropicSnapshot(opus: UsageWindow(label: "Opus (7d)", utilizationPercent: .nan),
                                    resetGrants: [grant])
        #expect(nan.limitResetOffers(now: now).isEmpty)
    }

    @Test("grant ids outside Claude Code's pattern are rejected")
    func grantIDs() {
        expectTrue(AnthropicResetGrant.isValidID("full-reset-2611"))
        expectTrue(AnthropicResetGrant.isValidID("a_b-9"))
        expectFalse(AnthropicResetGrant.isValidID(""))
        expectFalse(AnthropicResetGrant.isValidID("UPPER"))
        expectFalse(AnthropicResetGrant.isValidID("../x"))
        expectFalse(AnthropicResetGrant.isValidID(String(repeating: "a", count: 41)))
    }

    @Test("snapshot round-trips its grants and decodes history without them")
    func codable() throws {
        let snap = try resetsSnapshot()
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(AnthropicSnapshot.self, from: data)
        #expect(back == snap)
        let legacy = try JSONDecoder().decode(AnthropicSnapshot.self, from: Data(#"{"scoped":[]}"#.utf8))
        #expect(legacy.resetGrants.isEmpty)
    }
}

// MARK: - Service

@Suite("Claude limit reset service", .serialized)
struct ClaudeLimitResetServiceTests {
    fileprivate let reader = FixedReader()

    init() { StubURLProtocol.reset() }

    private func service(version: String? = "2.1.322") -> ClaudeLimitResetService {
        ClaudeLimitResetService(credentialReader: reader,
                                http: .stubbed(protocols: [StubURLProtocol.self]),
                                cliVersion: { version }, now: { now })
    }

    private func route(claim: StubURLProtocol.CannedResponse = .init(data: Data(#"{"result":"reset","resets_left":0}"#.utf8)),
                       status: String = Fixtures.anthropicUsageWithResets200,
                       profile: StubURLProtocol.CannedResponse = .init(data: Data(profileJSON.utf8))) {
        StubURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/oauth/profile": return profile
            case "/api/oauth/usage": return .init(data: Fixtures.data(status))
            default: return claim
            }
        }
    }

    @Test("prepare reads profile and status as the installed CLI, never writing the credential")
    func prepare() async throws {
        route()
        let attempt = try await service().prepare(kind: .fable)
        #expect(attempt.kind == .fable)
        #expect(attempt.grantID == "launch-2610-fable")
        #expect(attempt.grantLabel == "New model launch: one Fable reset")
        #expect(attempt.resetsLeft == 1)
        #expect(attempt.accountUUID == accountUUID)
        #expect(attempt.organizationUUID == orgUUID.lowercased())
        let captured = StubURLProtocol.captured
        #expect(captured.map { $0.url?.path ?? "" } == ["/api/oauth/profile", "/api/oauth/usage"])
        #expect(captured[1].url?.query == "cedar_ember=1")
        expectTrue(captured.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.322 (external, cli)" })
        expectTrue(captured.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
        expectTrue(captured.allSatisfy { $0.value(forHTTPHeaderField: "anthropic-beta") == AnthropicOAuth.betaHeader })
        #expect(reader.writeBacks == 0)
    }

    @Test("prepare without an offer of that kind fails before any claim")
    func prepareNoOffer() async {
        route(status: Fixtures.anthropicUsageWithResets200
            .replacingOccurrences(of: #""utilization": 95.0"#, with: #""utilization": 50.0"#))
        await #expect(throws: ClaudeLimitResetError.noEligibleReset) {
            try await service().prepare(kind: .weekly)
        }
        expectTrue(StubURLProtocol.captured.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test("no installed Claude Code: nothing is sent")
    func noCLI() async {
        route()
        await #expect(throws: ClaudeLimitResetError.cliUnavailable) {
            try await service(version: nil).prepare(kind: .fable)
        }
        #expect(StubURLProtocol.captured.isEmpty)
    }

    @Test("a credential that cannot be read reads as authorization")
    func credentialFailure() async {
        route()
        reader.failure = .credentials("locked")
        await #expect(throws: ClaudeLimitResetError.authorization) {
            try await service().prepare(kind: .fable)
        }
    }

    @Test("401 on the profile is an authorization error")
    func profile401() async {
        route(profile: .init(status: 401, data: Data("{}".utf8)))
        await #expect(throws: ClaudeLimitResetError.authorization) {
            try await service().prepare(kind: .fable)
        }
    }

    @Test("a profile without UUIDs fails closed")
    func profileWithoutUUIDs() async {
        route(profile: .init(data: Data(#"{"account":{"uuid":"not-a-uuid"},"organization":{}}"#.utf8)))
        await #expect(throws: ClaudeLimitResetError.failed) {
            try await service().prepare(kind: .fable)
        }
    }

    private func attempt(kind: ClaudeResetKind = .fable, grant: String = "launch-2610-fable",
                         account: String = accountUUID) -> ClaudeLimitResetAttempt {
        ClaudeLimitResetAttempt(kind: kind, grantID: grant, grantLabel: "x", resetsLeft: 1,
                                accountUUID: account, organizationUUID: orgUUID.lowercased())
    }

    @Test("consume re-checks, then posts program, grant and request id to the org")
    func consume() async throws {
        route()
        let attempt = attempt()
        let receipt = try await service().consume(attempt, retry: false)
        #expect(receipt == ClaudeLimitResetReceipt(outcome: .reset, resetsLeft: 0))
        let claim = try #require(StubURLProtocol.captured.last)
        #expect(claim.httpMethod == "POST")
        #expect(claim.url?.absoluteString
                == "https://api.anthropic.com/api/organizations/\(orgUUID.lowercased())/reset_rate_limits")
        #expect(claim.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(claim.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.322 (external, cli)")
        #expect(body(of: claim) == ["program": "cedar_ember", "grant_id": "launch-2610-fable",
                                    "request_id": attempt.id.uuidString.lowercased()])
        #expect(StubURLProtocol.captured.map { $0.url?.path ?? "" }
                == ["/api/oauth/profile", "/api/oauth/usage",
                    "/api/organizations/\(orgUUID.lowercased())/reset_rate_limits"])
    }

    @Test("a retry skips the eligibility re-check and reuses the request id")
    func retry() async throws {
        route(claim: .init(data: Data(#"{"result":"already_used"}"#.utf8)))
        let attempt = attempt()
        let receipt = try await service().consume(attempt, retry: true)
        #expect(receipt.outcome == .alreadyUsed)
        expectFalse(StubURLProtocol.captured.map { $0.url?.path ?? "" }.contains("/api/oauth/usage"))
        #expect(body(of: try #require(StubURLProtocol.captured.last))["request_id"] == attempt.id.uuidString.lowercased())
    }

    @Test("another account behind the credential stops the claim")
    func accountChanged() async {
        route()
        await #expect(throws: ClaudeLimitResetError.accountChanged) {
            try await service().consume(attempt(account: "99999999-2222-3333-4444-555555555555"), retry: false)
        }
        expectTrue(StubURLProtocol.captured.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test("a grant no longer offered stops the claim")
    func noLongerOffered() async {
        route()
        await #expect(throws: ClaudeLimitResetError.noEligibleReset) {
            try await service().consume(attempt(grant: "gone-grant"), retry: false)
        }
        expectTrue(StubURLProtocol.captured.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test("5xx, transport failure and an unreadable answer are uncertain")
    func uncertain() async {
        for claim in [StubURLProtocol.CannedResponse(status: 502, data: Data()),
                      .failing(.networkConnectionLost),
                      .init(data: Data("<html>".utf8))] {
            StubURLProtocol.reset()
            route(claim: claim)
            await #expect(throws: ClaudeLimitResetError.submissionUncertain) {
                try await service().consume(attempt(), retry: true)
            }
        }
    }

    @Test("429, 401 and 400 on the claim are definitive")
    func definitive() async {
        let cases: [(Int, ClaudeLimitResetError)] = [(429, .rateLimited), (401, .authorization),
                                                     (403, .authorization), (400, .failed)]
        for (status, expected) in cases {
            StubURLProtocol.reset()
            route(claim: .init(status: status, data: Data("{}".utf8)))
            await #expect(throws: expected) {
                try await service().consume(attempt(), retry: true)
            }
        }
    }

    @Test("an unknown result is never read as a reset")
    func unknownResult() async throws {
        route(claim: .init(data: Data(#"{"result":"brand_new"}"#.utf8)))
        #expect(try await service().consume(attempt(), retry: true).outcome == .unavailable)
    }

    @Test("an attempt with a tampered org or grant id is never sent")
    func tampered() async {
        route()
        let bad = ClaudeLimitResetAttempt(kind: .fable, grantID: "../x", grantLabel: "", resetsLeft: 1,
                                          accountUUID: accountUUID, organizationUUID: orgUUID.lowercased())
        await #expect(throws: ClaudeLimitResetError.failed) {
            try await service().consume(bad, retry: true)
        }
        expectTrue(StubURLProtocol.captured.allSatisfy { $0.httpMethod == "GET" })
    }
}

// MARK: - Provider

@Suite("AnthropicProvider asks for reset status only near the limit", .serialized)
struct AnthropicProviderResetStatusTests {
    let tmpCache: URL

    init() throws {
        StubURLProtocol.reset()
        tmpCache = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-reset-\(UUID().uuidString)")
        try Paths.ensureDir(tmpCache)
    }

    private func provider(version: String? = "2.1.322") -> AnthropicProvider {
        AnthropicProvider(credentialReader: FixedReader(),
                          cache: DiskCache(vendor: .anthropic, baseDir: tmpCache),
                          http: .stubbed(protocols: [StubURLProtocol.self]),
                          cliVersion: { version })
    }

    @Test("below 90%: one plain call with the app's usual User-Agent")
    func belowThreshold() async throws {
        StubURLProtocol.handler = { _ in .init(data: Fixtures.data(Fixtures.anthropicUsage200)) }
        _ = try await provider().fetchUsage(forceRefresh: true)
        let captured = StubURLProtocol.captured
        #expect(captured.count == 1)
        #expect(captured.first?.url?.query == nil)
        #expect(captured.first?.value(forHTTPHeaderField: "User-Agent") == AnthropicOAuth.userAgent)
    }

    @Test("crossing 90%: a second call as the CLI fills the grants, the next fetch makes one")
    func aboveThreshold() async throws {
        StubURLProtocol.handler = { request in
            .init(data: Fixtures.data(request.url?.query == "cedar_ember=1"
                ? Fixtures.anthropicUsageWithResets200
                : Fixtures.anthropicUsageWithResets200.replacingOccurrences(of: #""cedar_ember""#, with: #""ignored""#)))
        }
        let provider = provider()
        let outcome = try await provider.fetchUsage(forceRefresh: true)
        guard case .anthropic(let snap) = outcome.snapshot else { Issue.record("not anthropic"); return }
        #expect(snap.resetGrants.map(\.id) == ["full-reset-2611", "launch-2610-fable"])
        #expect(StubURLProtocol.captured.map { $0.url?.query ?? "" } == ["", "cedar_ember=1"])
        #expect(StubURLProtocol.captured.last?.value(forHTTPHeaderField: "User-Agent")
                == "claude-cli/2.1.322 (external, cli)")

        _ = try await provider.fetchUsage(forceRefresh: true)
        #expect(StubURLProtocol.captured.map { $0.url?.query ?? "" } == ["", "cedar_ember=1", "cedar_ember=1"])
    }

    @Test("a failed status call keeps the usage numbers")
    func statusFailureKeepsUsage() async throws {
        StubURLProtocol.handler = { request in
            request.url?.query == "cedar_ember=1"
                ? .init(status: 503, data: Data())
                : .init(data: Fixtures.data(Fixtures.anthropicUsageWithResets200))
        }
        let outcome = try await provider().fetchUsage(forceRefresh: true)
        guard case .anthropic(let snap) = outcome.snapshot else { Issue.record("not anthropic"); return }
        #expect(snap.weekly?.utilizationPercent == 95)
        #expect(outcome.lastError == nil)
    }

    @Test("without Claude Code installed the provider never presents itself as the CLI")
    func noCLI() async throws {
        StubURLProtocol.handler = { _ in .init(data: Fixtures.data(Fixtures.anthropicUsageWithResets200)) }
        _ = try await provider(version: nil).fetchUsage(forceRefresh: true)
        #expect(StubURLProtocol.captured.count == 1)
        #expect(StubURLProtocol.captured.first?.value(forHTTPHeaderField: "User-Agent") == AnthropicOAuth.userAgent)
    }
}
