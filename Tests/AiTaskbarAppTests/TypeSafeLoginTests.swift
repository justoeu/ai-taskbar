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
        ("CONSOLE.typesafe.ai", true),
        ("login.typesafe.ai", false),
        ("docs.typesafe.ai", false),
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

@Suite("TypeSafe card formatting") @MainActor
struct TypeSafeCardFormattingTests {
    @Test("used share of purchased credit")
    func used_percent() {
        expectTrue(TypeSafeCardView.usedPercent(TypeSafeBilling(spentUSD: 0, balanceUSD: 30, purchasedUSD: 30)) == 0)
        expectTrue(TypeSafeCardView.usedPercent(TypeSafeBilling(spentUSD: 0, balanceUSD: 7.5, purchasedUSD: 30)) == 75)
        // A top-up bonus above the purchase clamps to 0, an overdraw to 100.
        expectTrue(TypeSafeCardView.usedPercent(TypeSafeBilling(spentUSD: 0, balanceUSD: 40, purchasedUSD: 30)) == 0)
        expectTrue(TypeSafeCardView.usedPercent(TypeSafeBilling(spentUSD: 0, balanceUSD: -1, purchasedUSD: 30)) == 100)
    }

    @Test("no purchase reported, no bar")
    func used_percent_needs_denominator() {
        expectTrue(TypeSafeCardView.usedPercent(TypeSafeBilling(spentUSD: 0, balanceUSD: 5)) == nil)
        expectTrue(TypeSafeCardView.usedPercent(TypeSafeBilling(spentUSD: 0, balanceUSD: 5, purchasedUSD: 0)) == nil)
        expectTrue(TypeSafeCardView.usedPercent(TypeSafeBilling(spentUSD: 0, balanceUSD: .nan, purchasedUSD: 5)) == nil)
    }

    @Test("counts: exact under 100k, compact above")
    func counts() {
        let digits = { (s: String) in s.filter(\.isNumber) }
        #expect(digits(TypeSafeCardView.count(0)) == "0")
        #expect(digits(TypeSafeCardView.count(1_521)) == "1521")
        #expect(digits(TypeSafeCardView.count(99_999)) == "99999")
        #expect(TypeSafeCardView.count(250_000).hasSuffix("k"))
        #expect(digits(TypeSafeCardView.count(250_000)) == "250")
        #expect(TypeSafeCardView.count(2_700_000).hasSuffix("M"))
        #expect(digits(TypeSafeCardView.count(2_700_000)) == "27")
        #expect(TypeSafeCardView.count(3_000_000_000).hasSuffix("B"))
    }

    @Test("cycle label is re-rendered; unknown text passes through")
    func cycle_name() {
        let rendered = TypeSafeCardView.cycleName("September 2026")
        expectTrue(rendered?.contains("2026") ?? false)
        expectTrue(TypeSafeCardView.cycleName("Q3 cycle") == "Q3 cycle")
        expectTrue(TypeSafeCardView.cycleName("  ") == nil)
        expectTrue(TypeSafeCardView.cycleName(nil) == nil)
    }

    @Test("plans: known ids localized, others title-cased")
    func plans() {
        expectTrue(TypeSafeCardView.planLabel("pay_as_you_go") == L10n.localizedString("typesafe_plan_payg"))
        expectTrue(TypeSafeCardView.planLabel("free_plan") == L10n.localizedString("typesafe_plan_free"))
        expectTrue(TypeSafeCardView.planLabel("team-pro") == "Team Pro")
        expectTrue(TypeSafeCardView.planLabel("") == nil)
    }

    @Test("balance detail names the soonest expiry and counts the rest")
    func balance_detail() {
        let exp = Date(timeIntervalSince1970: 1_822_000_000)
        let b = TypeSafeBilling(spentUSD: 0, balanceUSD: 30, purchasedUSD: 30, credits: [
            TypeSafeCredit(amountUSD: 20, remainingUSD: 20, expiresAt: exp),
            TypeSafeCredit(amountUSD: 10, remainingUSD: 10, expiresAt: exp.addingTimeInterval(86_400)),
        ])
        let text = TypeSafeCardView.balanceDetail(b, usedPercent: 0)
        #expect(text.contains("0%"))
        #expect(text.contains(L10n.localizedString("typesafe_more_credits_fmt", 1)))
        #expect(TypeSafeCardView.balanceDetail(TypeSafeBilling(spentUSD: 0, balanceUSD: 1), usedPercent: nil).isEmpty)
    }
}
