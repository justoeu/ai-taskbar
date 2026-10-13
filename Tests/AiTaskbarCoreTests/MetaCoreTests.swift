import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("Meta vendor model (SDD-meta-muse §5)")
struct MetaVendorModelTests {
    @Test("VendorId.meta identity")
    func vendor_identity() {
        #expect(VendorId.meta.rawValue == "meta")
        #expect(VendorId.meta.displayName == "Muse (Meta)")
        #expect(VendorId.meta.symbolName == "m.square")
        #expect(VendorId.meta.dashboardURL?.absoluteString == "https://dev.meta.ai")
        #expect(VendorId.meta.statusPageURL?.absoluteString == "https://metastatus.com")
        #expect(VendorId.meta.reloginCommand == "muse login")
        expectTrue(VendorId.meta.reportsUtilization)
        expectFalse(VendorId.meta.isPrepaidOnly)
    }

    @Test("MetaSnapshot windows and maxUtilization")
    func snapshot_windows() {
        let snap = MetaSnapshot(
            planLabel: "Muse Code Power Usage",
            subscription: .active,
            session: UsageWindow(label: "Session", utilizationPercent: 37.5),
            weekly: UsageWindow(label: "Weekly", utilizationPercent: 12))
        let vendor = VendorSnapshot.meta(snap)
        #expect(vendor.vendorId == .meta)
        #expect(vendor.planLabel == "Muse Code Power Usage")
        #expect(vendor.windows.count == 2)
        #expect(vendor.maxUtilization == 37.5)
        #expect(vendor.menuBarDisplayPercentages.weekly == 12)
        #expect(vendor.menuBarDisplayPercentages.current == 37.5)
        #expect(vendor.menuBarResetWindows.dailyOrSession?.label == "Session")
        #expect(vendor.menuBarResetWindows.weekly?.label == "Weekly")
    }

    @Test("Pay-as-you-go snapshot has no windows and feeds no percentage")
    func snapshot_payg_no_windows() {
        let vendor = VendorSnapshot.meta(MetaSnapshot(subscription: .payAsYouGo))
        #expect(vendor.windows.isEmpty)
        #expect(vendor.maxUtilization == 0)
    }

    @Test("MetaSnapshot Codable round-trip")
    func snapshot_roundtrip() throws {
        let snap = MetaSnapshot(planLabel: "Pro", subscription: .billingIncomplete,
                                session: UsageWindow(label: "Session", utilizationPercent: 3))
        let data = try JSONEncoder().encode(VendorSnapshot.meta(snap))
        let back = try JSONDecoder().decode(VendorSnapshot.self, from: data)
        #expect(back == .meta(snap))
    }
}

@Suite("MetaConfig (SDD-meta-muse §6)")
struct MetaConfigTests {
    @Test("disabled by default, no key fields")
    func defaults() {
        let cfg = MetaConfig()
        expectFalse(cfg.enabled)
        #expect(cfg.sessionsDir == nil)
        #expect(cfg.authPath == nil)
        expectFalse(AppConfig().meta.enabled)
    }
}
