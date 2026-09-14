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

@Suite("CreditBaselineMath.decide — telling an expiry from ordinary spending")
struct CreditBaselineDecisionTests {
    private func obs(_ balance: Double, credits: Bool = true, promo: Bool = false) -> CreditObservation {
        CreditObservation(balance: balance, hasCredits: credits, hasPromo: promo)
    }
    private func stored(_ peak: Double, credits: Bool = true, promo: Bool = false) -> CreditBaseline {
        CreditBaseline(peak: peak, updatedAt: 0, hadCredits: credits, hadPromo: promo)
    }

    @Test("nothing stored seeds the baseline")
    func seeds() {
        #expect(CreditBaselineMath.decide(stored: nil, observation: obs(500)) == .seed)
    }

    @Test("a falling balance is ordinary consumption, not an expiry")
    func falling_is_consumption() {
        #expect(CreditBaselineMath.decide(stored: stored(500), observation: obs(400)) == .keep)
        // Even a savage drop: from the number alone this is indistinguishable
        // from a heavy day, so it must NOT be guessed at.
        #expect(CreditBaselineMath.decide(stored: stored(50_000), observation: obs(5)) == .keep)
    }

    @Test("a rise above the peak is a top-up")
    func rise_is_topup() {
        #expect(CreditBaselineMath.decide(stored: stored(500), observation: obs(900)) == .raise)
    }

    @Test("credits coming back after running out starts a new epoch")
    func credits_returning_rebaselines() {
        #expect(CreditBaselineMath.decide(stored: stored(50_000, credits: false),
                                          observation: obs(5_000, credits: true)) == .rebaseline)
    }

    @Test("a promo that disappears rebaselines even though the balance fell")
    func promo_ending_rebaselines() {
        // The motivating case: 50k promo expires, 5k purchased remains.
        #expect(CreditBaselineMath.decide(stored: stored(50_000, promo: true),
                                          observation: obs(5_000, promo: false)) == .rebaseline)
    }

    @Test("a promo that is still running changes nothing")
    func promo_still_active_keeps() {
        #expect(CreditBaselineMath.decide(stored: stored(50_000, promo: true),
                                          observation: obs(49_000, promo: true)) == .keep)
    }

    @Test("a promo appearing is not an ending")
    func promo_appearing_is_not_an_ending() {
        #expect(CreditBaselineMath.decide(stored: stored(500, promo: false),
                                          observation: obs(400, promo: true)) == .keep)
    }

    @Test("only .keep preserves the stored denominator")
    func adopts_observed_balance() {
        #expect(!BaselineDecision.keep.adoptsObservedBalance)
        for d in [BaselineDecision.seed, .rebaseline, .raise] {
            #expect(d.adoptsObservedBalance)
        }
    }
}

@Suite("CreditBaselineStore — persistence across refreshes", .serialized)
final class CreditBaselineStoreTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-taskbar-credits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // Swift Testing builds one instance per @Test, so without this every run
    // left a directory behind in TMPDIR (the repo convention elsewhere).
    deinit { try? FileManager.default.removeItem(at: dir) }

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

    @Test("an expiring promo re-seeds the denominator instead of over-reporting")
    func promo_expiry_reseeds() {
        let s = store()
        // 50k promo running.
        #expect(s.record(CreditObservation(balance: 50_000, hasCredits: true, hasPromo: true)) == 50_000)
        #expect(s.record(CreditObservation(balance: 49_000, hasCredits: true, hasPromo: true)) == 50_000)
        // Promo expires, 5k purchased remains. Without the epoch signal the
        // bar would read 90% consumed forever.
        #expect(s.record(CreditObservation(balance: 5_000, hasCredits: true, hasPromo: false)) == 5_000)
        // And it keeps behaving normally afterwards.
        #expect(s.record(CreditObservation(balance: 4_500, hasCredits: true, hasPromo: false)) == 5_000)
    }

    @Test("credits returning after zero re-seed rather than inherit the old peak")
    func credits_returning_reseeds() {
        let s = store()
        #expect(s.record(CreditObservation(balance: 900, hasCredits: true)) == 900)
        #expect(s.record(CreditObservation(balance: 0, hasCredits: false)) == 900)
        #expect(s.record(CreditObservation(balance: 100, hasCredits: true)) == 100)
    }

    @Test("the epoch flags survive a relaunch")
    func flags_persist() {
        #expect(store().record(CreditObservation(balance: 50_000, hasCredits: true, hasPromo: true)) == 50_000)
        // A fresh instance must still know a promo was running.
        #expect(store().record(CreditObservation(balance: 5_000, hasCredits: true, hasPromo: false)) == 5_000)
    }

    @Test("a baseline written before the epoch flags existed still loads")
    func legacy_file_loads() throws {
        try #"{"peak": 800, "updatedAt": 0}"#.write(
            to: dir.appendingPathComponent("openai.json"), atomically: true, encoding: .utf8)
        let loaded = try #require(store().load())
        #expect(loaded.peak == 800)
        #expect(!loaded.hadCredits)
        #expect(!loaded.hadPromo)
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
        // The second call is what proves retention: returning 777 for a lower
        // balance can only happen if the peak survived in memory.
        #expect(bad.recordAndPeak(balance: 700) == 777)
    }

    @Test("a corrupted baseline file is rejected and re-seeded, not trusted forever")
    func corrupt_file_reseeds() throws {
        let url = dir.appendingPathComponent("openai.json")
        try #"{"peak": null, "updatedAt": 0}"#.write(to: url, atomically: true, encoding: .utf8)
        expectTrue(store().load() == nil)
        // A NaN peak would poison every percentage if it were accepted.
        try #"{"peak": 1e999, "updatedAt": 0}"#.write(to: url, atomically: true, encoding: .utf8)
        expectTrue(store().load() == nil)
        try #"{"peak": -5, "updatedAt": 0}"#.write(to: url, atomically: true, encoding: .utf8)
        expectTrue(store().load() == nil)
        #expect(store().recordAndPeak(balance: 42) == 42)
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
        // Every flag non-default, so dropping any one of them is detectable.
        // `isUnlimited` in particular was uncovered: false is the default, so a
        // silent drop would have looked identical.
        let original = OpenAICreditsInfo(
            balance: 10,
            peakBalance: nil,
            localMessages: CreditMessageRange(low: 1, high: 2),
            cloudMessages: CreditMessageRange(low: 3, high: 4),
            hasCredits: true,
            isUnlimited: true,
            overageLimitReached: true,
            isFundingRequests: true)
        let updated = original.withPeakBalance(40)
        #expect(updated.peakBalance == 40)
        #expect(updated.balance == 10)
        #expect(updated.localMessages == CreditMessageRange(low: 1, high: 2))
        #expect(updated.cloudMessages == CreditMessageRange(low: 3, high: 4))
        #expect(updated.hasCredits)
        #expect(updated.isUnlimited)
        #expect(updated.overageLimitReached)
        #expect(updated.isFundingRequests)
        // Unmetered wins over the baseline: still no bar.
        expectTrue(updated.consumedPercent == nil)
    }

    @Test("a metered copy keeps its percentage after withPeakBalance")
    func with_peak_metered_percent() {
        let metered = OpenAICreditsInfo(balance: 10, peakBalance: nil, hasCredits: true)
        #expect(metered.withPeakBalance(40).consumedPercent == 75)
    }

    @Test("a peak equal to the balance draws no bar (first sighting)")
    func first_sighting_draws_no_bar() {
        expectTrue(info(balance: 500, peak: 500).consumedPercent == nil)
        // One observed unit of consumption is enough to make it meaningful.
        #expect(info(balance: 499, peak: 500).consumedPercent == 0.2)
    }

    @Test("a missing balance keeps the block but draws no bar")
    func missing_balance_keeps_block() {
        let unmetered = OpenAICreditsInfo(balance: nil, peakBalance: nil,
                                          localMessages: CreditMessageRange(low: 1, high: 2),
                                          hasCredits: true, isUnlimited: true)
        expectTrue(unmetered.consumedPercent == nil)
        #expect(unmetered.isWorthShowing)
        #expect(unmetered.localMessages == CreditMessageRange(low: 1, high: 2))
        #expect(!unmetered.isExhausted)
    }

    @Test("exhausted means a zero balance on a metered account")
    func exhausted_flag() {
        #expect(OpenAICreditsInfo(balance: 0, hasCredits: true).isExhausted)
        #expect(!OpenAICreditsInfo(balance: 5, hasCredits: true).isExhausted)
        #expect(!OpenAICreditsInfo(balance: 0, hasCredits: true, isUnlimited: true).isExhausted)
    }

    @Test("isWorthShowing hides a plan that never had credits")
    func worth_showing() {
        #expect(!OpenAICreditsInfo(balance: 0, hasCredits: false).isWorthShowing)
        #expect(OpenAICreditsInfo(balance: 0, hasCredits: true).isWorthShowing)
        #expect(OpenAICreditsInfo(balance: 5, hasCredits: false).isWorthShowing)
    }

    @Test("Codable round-trips preserve every field")
    func codable_round_trip() throws {
        let info = OpenAICreditsInfo(
            balance: 4890.316252, peakBalance: 5000,
            localMessages: CreditMessageRange(low: 1223, high: 6357),
            cloudMessages: CreditMessageRange(low: 196, high: 1223),
            hasCredits: true, isUnlimited: false,
            overageLimitReached: true, isFundingRequests: true)
        let decoded = try SharedCoders.decoder.decode(
            OpenAICreditsInfo.self, from: SharedCoders.encoder.encode(info))
        #expect(decoded == info)
    }

    @Test("a persisted reversed range is normalized on decode, not rendered backwards")
    func decoded_range_normalizes() throws {
        let decoded = try SharedCoders.decoder.decode(
            CreditMessageRange.self, from: Data(#"{"low": 9, "high": 2}"#.utf8))
        #expect(decoded == CreditMessageRange(low: 2, high: 9))
        #expect(decoded.low == 2)
        #expect(decoded.high == 9)
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
