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
}
