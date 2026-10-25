import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("LastSeenWindow store and Muse weekly carry", .serialized)
struct LastSeenWindowTests {
    let dir: URL
    let resetsAt = Date(timeIntervalSince1970: 1_800_000_000)
    let t0 = Date(timeIntervalSince1970: 1_799_000_000)

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-lastseen-\(UUID().uuidString)")
        try Paths.ensureDir(dir)
    }

    private func weekly(_ percent: Double, resetsAt: Date? = nil) -> UsageWindow {
        UsageWindow(label: "Weekly (7d)", utilizationPercent: percent, resetsAt: resetsAt ?? self.resetsAt)
    }

    @Test("a recorded reading survives a new store instance (disk round-trip)")
    func persists_across_instances() {
        LastSeenWindowStore(vendor: .meta, baseDir: dir).record(weekly(100), at: t0)
        let reloaded = LastSeenWindowStore(vendor: .meta, baseDir: dir)
        #expect(reloaded.load()?.window.utilizationPercent == 100)
        #expect(reloaded.load()?.observedAt == t0)
        #expect(reloaded.fileURL.lastPathComponent == "meta.json")
    }

    @Test("an unchanged reading is not re-stamped within the refresh interval")
    func unchanged_reading_keeps_time() {
        let store = LastSeenWindowStore(vendor: .meta, baseDir: dir)
        store.record(weekly(90), at: t0)
        store.record(weekly(90), at: t0.addingTimeInterval(60))
        #expect(store.load()?.observedAt == t0)
        store.record(weekly(90), at: t0.addingTimeInterval(LastSeenWindowStore.refreshInterval))
        #expect(store.load()?.observedAt == t0.addingTimeInterval(LastSeenWindowStore.refreshInterval))
    }

    @Test("a changed reading is stored at once")
    func changed_reading_overwrites() {
        let store = LastSeenWindowStore(vendor: .meta, baseDir: dir)
        store.record(weekly(90), at: t0)
        store.record(weekly(95), at: t0.addingTimeInterval(60))
        #expect(store.load()?.window.utilizationPercent == 95)
        #expect(store.load()?.observedAt == t0.addingTimeInterval(60))
    }

    @Test("carried only before its reset")
    func carried_until_reset() {
        let store = LastSeenWindowStore(vendor: .meta, baseDir: dir)
        store.record(weekly(100), at: t0)
        #expect(store.carried(at: t0.addingTimeInterval(3600))?.window.utilizationPercent == 100)
        #expect(store.carried(at: resetsAt) == nil)
        #expect(store.carried(at: resetsAt.addingTimeInterval(1)) == nil)
    }

    @Test("a window without a reset date never carries")
    func no_reset_never_carries() {
        let noReset = LastSeenWindow(window: UsageWindow(label: "Weekly", utilizationPercent: 50),
                                     observedAt: t0)
        expectFalse(noReset.isCarriable(at: t0, scope: nil))
    }

    @Test("a reading stamped in the future (clock skew) does not carry")
    func future_reading_does_not_carry() {
        let skewed = LastSeenWindow(window: weekly(50), observedAt: t0.addingTimeInterval(60))
        expectFalse(skewed.isCarriable(at: t0, scope: nil))
    }

    @Test("a reading carries only under the scope (plan) it was taken in")
    func carried_only_in_same_scope() {
        let store = LastSeenWindowStore(vendor: .meta, baseDir: dir)
        store.record(weekly(100), scope: "Muse Code Pro", at: t0)
        #expect(store.carried(at: t0, scope: "Muse Code Pro")?.window.utilizationPercent == 100)
        #expect(store.carried(at: t0, scope: "Muse Code Max") == nil)
        #expect(store.carried(at: t0, scope: nil) == nil)
    }

    @Test("a scope change is stored at once, even with the same window")
    func scope_change_overwrites() {
        let store = LastSeenWindowStore(vendor: .meta, baseDir: dir)
        store.record(weekly(50), scope: "A", at: t0)
        store.record(weekly(50), scope: "B", at: t0.addingTimeInterval(60))
        #expect(store.load()?.scope == "B")
    }

    @Test("clear forgets the reading in memory and on disk")
    func clear_forgets() {
        let store = LastSeenWindowStore(vendor: .meta, baseDir: dir)
        store.record(weekly(100), at: t0)
        store.clear()
        #expect(store.load() == nil)
        expectFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(LastSeenWindowStore(vendor: .meta, baseDir: dir).load() == nil)
        store.clear()   // clearing nothing is fine
        #expect(store.load() == nil)
    }

    @Test("a miss is remembered: no disk retry per read")
    func miss_is_remembered() throws {
        let store = LastSeenWindowStore(vendor: .meta, baseDir: dir)
        #expect(store.load() == nil)
        // Written behind the store's back: the remembered miss still answers.
        let other = LastSeenWindowStore(vendor: .meta, baseDir: dir)
        other.record(weekly(70), at: t0)
        #expect(store.load() == nil)
        // A record through the store itself replaces the remembered miss.
        store.record(weekly(80), at: t0)
        #expect(store.load()?.window.utilizationPercent == 80)
    }

    @Test("an empty or corrupt file reads as nothing stored")
    func corrupt_file_is_nothing() throws {
        let store = LastSeenWindowStore(vendor: .meta, baseDir: dir)
        #expect(store.load() == nil)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(LastSeenWindowStore(vendor: .meta, baseDir: dir).carried(at: t0) == nil)
    }

    @Test("MetaSnapshot carries a weekly only for an active subscription without its own")
    func snapshot_carry_rules() {
        let carried = LastSeenWindow(window: weekly(100), observedAt: t0)
        let idle = MetaSnapshot(planLabel: "Max", subscription: .active).carryingWeekly(carried)
        #expect(idle.weekly?.utilizationPercent == 100)
        #expect(idle.weeklyLastSeenAt == t0)
        #expect(VendorSnapshot.meta(idle).maxUtilization == 100)
        #expect(VendorSnapshot.meta(idle).menuBarDisplayPercentages.weekly == 100)

        let live = MetaSnapshot(subscription: .active, weekly: weekly(20)).carryingWeekly(carried)
        #expect(live.weekly?.utilizationPercent == 20)
        #expect(live.weeklyLastSeenAt == nil)

        let payg = MetaSnapshot(subscription: .payAsYouGo).carryingWeekly(carried)
        #expect(payg.weekly == nil)
        let billing = MetaSnapshot(subscription: .billingIncomplete).carryingWeekly(carried)
        #expect(billing.weekly == nil)

        // A response with a session window but no weekly is not the idle
        // shape: shown as sent.
        let sessionOnly = MetaSnapshot(subscription: .active,
                                       session: UsageWindow(label: "Session", utilizationPercent: 5))
        expectFalse(sessionOnly.acceptsCarriedWeekly)
        #expect(sessionOnly.carryingWeekly(carried).weekly == nil)

        let nothing = MetaSnapshot(subscription: .active).carryingWeekly(nil)
        #expect(nothing.weekly == nil)
        #expect(nothing.weeklyLastSeenAt == nil)
    }

    @Test("weeklyLastSeenAt round-trips, and an old cache without it decodes as live")
    func snapshot_codable() throws {
        let snap = MetaSnapshot(subscription: .active, weekly: weekly(100), weeklyLastSeenAt: t0)
        let decoded = try SharedCoders.decoder.decode(MetaSnapshot.self,
                                                      from: SharedCoders.encoder.encode(snap))
        #expect(decoded == snap)
        let old = MetaSnapshot(subscription: .active, weekly: weekly(10))
        let oldDecoded = try SharedCoders.decoder.decode(MetaSnapshot.self,
                                                         from: SharedCoders.encoder.encode(old))
        #expect(oldDecoded.weeklyLastSeenAt == nil)
    }

    @Test("a cache entry written before weeklyLastSeenAt existed decodes as live")
    func pre_field_cache_literal() throws {
        let json = #"{"planLabel":"Max","subscription":"active","weekly":{"label":"Weekly (7d)","utilizationPercent":40}}"#
        let decoded = try SharedCoders.decoder.decode(MetaSnapshot.self, from: Data(json.utf8))
        #expect(decoded.weekly?.utilizationPercent == 40)
        #expect(decoded.weeklyLastSeenAt == nil)
    }

    @Test("a last-seen time without a weekly window is dropped")
    func last_seen_requires_weekly() {
        #expect(MetaSnapshot(subscription: .active, weeklyLastSeenAt: t0).weeklyLastSeenAt == nil)
    }
}
