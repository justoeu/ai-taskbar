import Testing
import Foundation
@testable import AiTaskbarApp
@testable import AiTaskbarCore

@Suite("TypeSafe in-app login")
struct TypeSafeLoginTests {
    @Test("cookies are captured only once the console itself is showing", arguments: [
        ("https://console.typesafe.ai/usage", true),
        ("https://console.typesafe.ai/", true),
        ("https://console.typesafe.ai/login", false),
        ("https://console.typesafe.ai/login/callback", false),
        ("https://console.typesafe.ai/signup", false),
        ("https://console.typesafe.ai/auth/verify", false),
        ("http://console.typesafe.ai/usage", false),
        ("https://login.typesafe.ai/", false),
        ("https://accounts.google.com/o/oauth2", false),
        ("https://console.typesafe.ai.evil.com/usage", false),
    ])
    func signed_in_page(_ raw: String, _ expected: Bool) {
        #expect(TypeSafeLoginController.isSignedInPage(URL(string: raw)) == expected, "\(raw)")
    }

    @Test("no URL is not signed in")
    func no_url() {
        #expect(!TypeSafeLoginController.isSignedInPage(nil))
    }

    @Test("only TypeSafe cookie domains are read", arguments: [
        ("console.typesafe.ai", true),
        (".typesafe.ai", true),
        ("typesafe.ai", true),
        ("login.typesafe.ai", true),
        ("evil-typesafe.ai", false),
        ("typesafe.ai.evil.com", false),
        (".google.com", false),
    ])
    func domains(_ domain: String, _ expected: Bool) {
        #expect(TypeSafeLoginController.isTypeSafeDomain(domain) == expected, "\(domain)")
    }

    @Test("the login page is the console's own")
    func login_url() {
        #expect(TypeSafeLoginController.loginURL.absoluteString == "https://console.typesafe.ai/login")
    }
}

@Suite("TypeSafe card rendering")
struct TypeSafeCardRenderingTests {
    @Test("a TypeSafe snapshot renders its card even with no windows")
    func typesafe_renders_without_windows() {
        let snap = VendorSnapshot.typesafe(TypeSafeSnapshot(models: [TypeSafeModel(name: "jev-latest")]))
        #expect(snap.windows.isEmpty)
        #expect(VendorSectionView.rendersSnapshot(snap, vendorId: .typesafe))
    }

    @Test("empty windows still read as schema drift for utilization vendors")
    func utilization_vendor_empty_windows_warns() {
        let snap = VendorSnapshot.typesafe(TypeSafeSnapshot())
        #expect(!VendorSectionView.rendersSnapshot(snap, vendorId: .anthropic))
    }
}
