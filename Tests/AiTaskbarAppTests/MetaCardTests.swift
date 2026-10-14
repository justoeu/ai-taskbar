import Testing
import Foundation
@testable import AiTaskbarApp
import AiTaskbarCore

@Suite("Meta card rendering gates (SDD-meta-muse §4)")
struct MetaCardTests {
    @Test("pay-as-you-go snapshot renders despite empty windows")
    func payg_renders() {
        let snap = VendorSnapshot.meta(MetaSnapshot(subscription: .payAsYouGo))
        expectTrue(VendorSectionView.rendersSnapshot(snap, vendorId: .meta))
    }

    @Test("active idle snapshot renders despite empty windows")
    func idle_renders() {
        let snap = VendorSnapshot.meta(MetaSnapshot(planLabel: "Pro", subscription: .active))
        expectTrue(VendorSectionView.rendersSnapshot(snap, vendorId: .meta))
    }

    @Test("cost footer supports Meta local tokens")
    @MainActor func cost_footer_supported() {
        expectTrue(CostEstimator.supportedVendors.contains(.meta))
    }

    @Test("rotating label skips window-less Meta snapshots")
    func rotating_skips_windowless() {
        let payg = VendorSnapshot.meta(MetaSnapshot(subscription: .payAsYouGo))
        expectFalse(MenuBarLabelView.isRotatingCandidate(vendorId: .meta, snapshot: payg))
        let active = VendorSnapshot.meta(MetaSnapshot(
            subscription: .active,
            session: UsageWindow(label: "Session (5h)", utilizationPercent: 10)))
        expectTrue(MenuBarLabelView.isRotatingCandidate(vendorId: .meta, snapshot: active))
        expectTrue(MenuBarLabelView.isRotatingCandidate(vendorId: .meta, snapshot: nil))
        expectFalse(MenuBarLabelView.isRotatingCandidate(vendorId: .typesafe, snapshot: nil))
    }
}
