import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("VendorSnapshot + UsageWindow models")
struct SnapshotModelTests {
    @Test("UsageWindow Equatable + Codable round-trip")
    func usage_window_round_trip() throws {
        let w = UsageWindow(label: "Session (5h)",
                            utilizationPercent: 47.0,
                            resetsAt: Date(timeIntervalSince1970: 1_764_201_600),
                            detail: "$2.45 / $5.00")
        let data = try JSONEncoder().encode(w)
        let back = try JSONDecoder().decode(UsageWindow.self, from: data)
        #expect(back == w)
    }

    @Test("VendorSnapshot.vendorId reflects the case")
    func vendor_id_reflects_case() {
        #expect(VendorSnapshot.anthropic(.init()).vendorId == .anthropic)
        #expect(VendorSnapshot.openai(.init()).vendorId == .openai)
        #expect(VendorSnapshot.zai(.init()).vendorId == .zai)
        #expect(VendorSnapshot.openrouter(.init()).vendorId == .openrouter)
        #expect(VendorSnapshot.kimi(.init()).vendorId == .kimi)
    }

    @Test("planLabel passes through to each variant")
    func planLabel_passes_through() {
        let anthropic = VendorSnapshot.anthropic(.init(planLabel: "Claude Max"))
        let openai = VendorSnapshot.openai(.init(planLabel: "ChatGPT Pro"))
        let zai = VendorSnapshot.zai(.init(planLabel: "GLM Lite"))
        let or = VendorSnapshot.openrouter(.init(planLabel: "OR Tier 1"))
        let kimi = VendorSnapshot.kimi(.init(planLabel: "Kimi"))
        #expect(anthropic.planLabel == "Claude Max")
        #expect(openai.planLabel == "ChatGPT Pro")
        #expect(zai.planLabel == "GLM Lite")
        #expect(or.planLabel == "OR Tier 1")
        #expect(kimi.planLabel == "Kimi")
    }

    @Test("windows flattens optional fields per vendor")
    func windows_flattens_per_vendor() {
        let session = UsageWindow(label: "Session", utilizationPercent: 10)
        let weekly = UsageWindow(label: "Weekly", utilizationPercent: 5)
        let opus = UsageWindow(label: "Opus", utilizationPercent: 1)

        let withAll = VendorSnapshot.anthropic(.init(
            session: session, weekly: weekly, opus: opus))
        #expect(withAll.windows.count == 3)

        let withSomeNil = VendorSnapshot.anthropic(.init(session: session))
        #expect(withSomeNil.windows.count == 1)

        let openrouterFull = VendorSnapshot.openrouter(.init(
            balance: session, daily: weekly, weekly: weekly, monthly: weekly))
        #expect(openrouterFull.windows.count == 4)
    }

    @Test("maxUtilization picks the worst window or zero")
    func max_utilization_picks_worst() {
        let lo = UsageWindow(label: "lo", utilizationPercent: 10)
        let hi = UsageWindow(label: "hi", utilizationPercent: 88)
        let snap = VendorSnapshot.anthropic(.init(session: lo, weekly: hi))
        #expect(snap.maxUtilization == 88)
        // No windows → 0.
        let empty = VendorSnapshot.kimi(.init())
        #expect(empty.maxUtilization == 0)
    }

    @Test("VendorSnapshot Equatable + Codable round-trip")
    func vendor_snapshot_round_trip() throws {
        let session = UsageWindow(label: "Session", utilizationPercent: 47)
        let credits = UsageWindow(label: "Usage credits", utilizationPercent: 12.25,
                                  detail: "$2.45 / $20.00")
        let fable = UsageWindow(label: "Fable (7d)", utilizationPercent: 88)
        let snap = VendorSnapshot.anthropic(.init(
            planLabel: "Claude Max", session: session, scoped: [fable], credits: credits))
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(VendorSnapshot.self, from: data)
        #expect(back == snap)
    }
}

@Suite("FetchOutcome")
struct FetchOutcomeTests {
    @Test("FetchOutcome stores all fields")
    func fetch_outcome_stores_fields() {
        let when = Date(timeIntervalSince1970: 1_000_000)
        let err = FetchError(status: 429, body: "rate limit")
        let snap = VendorSnapshot.kimi(.init())
        let outcome = FetchOutcome(snapshot: snap,
                                   isStale: true,
                                   lastError: err,
                                   cacheAge: 30,
                                   fetchedAt: when)
        #expect(outcome.snapshot == snap)
        #expect(outcome.isStale)
        #expect(outcome.lastError == err)
        #expect(outcome.cacheAge == 30)
        #expect(outcome.fetchedAt == when)
    }
}
