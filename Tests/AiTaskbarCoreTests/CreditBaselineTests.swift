import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("CreditBaselineMath — the denominator the API never sends")
struct CreditBaselineMathTests {
    @Test("the first sighting seeds the peak")
    func first_sighting_seeds() {
        #expect(CreditBaselineMath.updatedPeak(stored: nil, balance: 500) == 500)
    }

    @Test("a seeded baseline reads 0% consumed")
    func seeded_is_zero() {
        #expect(CreditBaselineMath.consumedPercent(peak: 500, balance: 500) == 0)
    }

    @Test("draining leaves the peak where it is")
    func draining_keeps_peak() {
        #expect(CreditBaselineMath.updatedPeak(stored: 500, balance: 400) == 500)
    }

    @Test("consumption is measured against the peak")
    func consumed_against_peak() {
        #expect(CreditBaselineMath.consumedPercent(peak: 500, balance: 400) == 20)
    }

    @Test("a balance above the peak is a top-up and re-baselines")
    func topup_rebaselines() {
        #expect(CreditBaselineMath.updatedPeak(stored: 500, balance: 900) == 900)
        #expect(CreditBaselineMath.consumedPercent(peak: 900, balance: 900) == 0)
    }

    @Test("a zero peak yields no percentage rather than a division by zero")
    func zero_peak_is_nil() {
        expectTrue(CreditBaselineMath.consumedPercent(peak: 0, balance: 0) == nil)
        expectTrue(CreditBaselineMath.consumedPercent(peak: -10, balance: 5) == nil)
    }

    @Test("a depleted or negative balance reads fully consumed")
    func negative_balance_is_full() {
        #expect(CreditBaselineMath.consumedPercent(peak: 100, balance: 0) == 100)
        #expect(CreditBaselineMath.consumedPercent(peak: 100, balance: -5) == 100)
    }

    @Test("non-finite input yields no bar rather than a misleading number")
    func non_finite_is_contained() {
        expectTrue(CreditBaselineMath.consumedPercent(peak: 100, balance: .nan) == nil)
        expectTrue(CreditBaselineMath.consumedPercent(peak: 100, balance: .infinity) == nil)
        expectTrue(CreditBaselineMath.consumedPercent(peak: .nan, balance: 10) == nil)
        #expect(CreditBaselineMath.updatedPeak(stored: 500, balance: .nan) == 500)
    }

    @Test("a balance above the peak clamps to 0% instead of going negative")
    func above_peak_clamps() {
        #expect(CreditBaselineMath.consumedPercent(peak: 100, balance: 250) == 0)
    }
}

@Suite("CreditBaselineStore — persistence across refreshes", .serialized)
struct CreditBaselineStoreTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-taskbar-credits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func store() -> CreditBaselineStore {
        CreditBaselineStore(vendor: .openai, baseDir: dir)
    }

    @Test("the first balance becomes the denominator")
    func seeds_on_first_balance() {
        #expect(store().recordAndPeak(balance: 5000) == 5000)
    }

    @Test("consumption keeps the original denominator, across instances")
    func peak_survives_a_relaunch() {
        #expect(store().recordAndPeak(balance: 5000) == 5000)
        // A fresh instance reads the persisted file, as a relaunch would.
        #expect(store().recordAndPeak(balance: 4890.316252) == 5000)
    }

    @Test("a top-up raises the persisted denominator")
    func topup_raises_peak() {
        #expect(store().recordAndPeak(balance: 5000) == 5000)
        #expect(store().recordAndPeak(balance: 4000) == 5000)
        #expect(store().recordAndPeak(balance: 9000) == 9000)
        #expect(store().recordAndPeak(balance: 8000) == 9000)
    }

    @Test("the baseline lands on disk under the vendor's name")
    func writes_named_file() throws {
        _ = store().recordAndPeak(balance: 1234)
        let url = dir.appendingPathComponent("openai.json")
        expectTrue(FileManager.default.fileExists(atPath: url.path))
        let decoded = try SharedCoders.decoder.decode(CreditBaseline.self,
                                                      from: Data(contentsOf: url))
        #expect(decoded.peak == 1234)
    }

    @Test("reset clears memory and disk so the next balance re-seeds")
    func reset_reseeds() {
        let s = store()
        #expect(s.recordAndPeak(balance: 5000) == 5000)
        s.reset()
        expectTrue(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("openai.json").path))
        #expect(s.recordAndPeak(balance: 100) == 100)
    }

    @Test("an unwritable directory degrades to an in-memory baseline, never a crash")
    func unwritable_dir_is_survivable() {
        let bad = CreditBaselineStore(
            vendor: .openai,
            baseDir: URL(fileURLWithPath: "/dev/null/nope-\(UUID().uuidString)"))
        #expect(bad.recordAndPeak(balance: 777) == 777)
    }
}

@Suite("OpenAICreditsInfo — credits are a quantity")
struct OpenAICreditsInfoTests {
    private func info(balance: Double, peak: Double?, unlimited: Bool = false) -> OpenAICreditsInfo {
        OpenAICreditsInfo(balance: balance, peakBalance: peak, isUnlimited: unlimited)
    }

    @Test("no baseline means no bar, not a fabricated zero")
    func no_peak_no_percent() {
        expectTrue(info(balance: 100, peak: nil).consumedPercent == nil)
    }

    @Test("unlimited credits never produce a bar")
    func unlimited_no_percent() {
        expectTrue(info(balance: 100, peak: 500, unlimited: true).consumedPercent == nil)
    }

    @Test("consumption is derived from the baseline")
    func percent_from_peak() {
        #expect(info(balance: 400, peak: 500).consumedPercent == 20)
    }

    @Test("withPeakBalance carries every other field through untouched")
    func with_peak_preserves_fields() {
        let original = OpenAICreditsInfo(
            balance: 10,
            peakBalance: nil,
            localMessages: CreditMessageRange(low: 1, high: 2),
            cloudMessages: CreditMessageRange(low: 3, high: 4),
            hasCredits: true,
            isUnlimited: false,
            overageLimitReached: true,
            isFundingRequests: true)
        let updated = original.withPeakBalance(40)
        #expect(updated.peakBalance == 40)
        #expect(updated.balance == 10)
        #expect(updated.localMessages == CreditMessageRange(low: 1, high: 2))
        #expect(updated.cloudMessages == CreditMessageRange(low: 3, high: 4))
        #expect(updated.hasCredits)
        #expect(updated.overageLimitReached)
        #expect(updated.isFundingRequests)
        #expect(updated.consumedPercent == 75)
    }

    @Test("a reversed wire range is normalized, not trusted blindly")
    func range_normalizes() {
        #expect(CreditMessageRange(low: 9, high: 2) == CreditMessageRange(low: 2, high: 9))
    }

    @Test("a range needs two elements; anything else is nil")
    func range_requires_two_elements() {
        expectTrue(CreditMessageRange(wire: nil) == nil)
        expectTrue(CreditMessageRange(wire: []) == nil)
        expectTrue(CreditMessageRange(wire: [5]) == nil)
        #expect(CreditMessageRange(wire: [5, 10]) == CreditMessageRange(low: 5, high: 10))
    }
}
