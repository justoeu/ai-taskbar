import Testing
import SwiftUI
@testable import AiTaskbarApp
import AiTaskbarCore

@MainActor
@Suite("Vendor brand icon")
struct VendorBrandIconTests {
    @Test("enabled vendors use their own brand colour")
    func enabled_tint() {
        #expect(VendorBrandIcon.tint(for: .anthropic, isEnabled: true) == .orange)
        #expect(VendorBrandIcon.tint(for: .typesafe, isEnabled: true)
                == Color(red: 0.30, green: 0.75, blue: 0.35))
    }

    @Test("every disabled vendor gets the same grey, never a brand colour")
    func disabled_tint() {
        for vendor in VendorId.allCases {
            #expect(VendorBrandIcon.tint(for: vendor, isEnabled: false) == Color.secondary.opacity(0.6), "\(vendor)")
            #expect(VendorBrandIcon.tint(for: vendor, isEnabled: false) != AnalyticsFormatters.vendorColor(for: vendor),
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
