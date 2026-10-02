import Testing
import SwiftUI
@testable import AiTaskbarApp
import AiTaskbarCore

@MainActor
@Suite("Vendor brand icon")
struct VendorBrandIconTests {
    @Test("active vendors use their brand colour, inactive ones grey")
    func tint() {
        for vendor in VendorId.allCases {
            #expect(VendorBrandIcon.tint(for: vendor, isActive: true) == AnalyticsFormatters.vendorColor(for: vendor),
                    "\(vendor)")
            #expect(VendorBrandIcon.tint(for: vendor, isActive: false) != AnalyticsFormatters.vendorColor(for: vendor),
                    "\(vendor)")
        }
    }

    @Test("every vendor has its own brand colour")
    func distinct_colours() {
        let colours = VendorId.allCases.map { AnalyticsFormatters.vendorColor(for: $0) }
        for (i, a) in colours.enumerated() {
            for b in colours[(i + 1)...] { #expect(a != b) }
        }
    }
}
