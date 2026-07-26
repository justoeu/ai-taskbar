import Testing
import AiTaskbarCore
@testable import AiTaskbarApp

@Suite("opencode footer formatting")
struct OpencodeFooterTests {

    /// The three buckets differ by orders of magnitude on real data — 169M
    /// input against 2.7B cache reads — so a single total would bury the
    /// number that dominates. Cache has to survive into the string.
    @Test("all three buckets appear, scaled independently")
    func compact_tokens_shows_three_buckets() {
        let usage = ModelUsage(inputTokens: 169_000_000,
                               outputTokens: 11_700_000,
                               cacheReadTokens: 2_725_000_000)
        let s = CostFooterView.compactTokens(usage)
        #expect(s == "169M in · 2.7B cache · 12M out")
    }

    /// A model with no cache reads should not render an empty "0 cache"
    /// segment — the separator arithmetic is where that kind of thing breaks.
    @Test("cache segment is omitted when there are no cache reads")
    func compact_tokens_omits_empty_cache() {
        let s = CostFooterView.compactTokens(
            ModelUsage(inputTokens: 1_500, outputTokens: 200))
        #expect(s == "2k in · 200 out")
    }

    /// Boundaries between the units. 999 must stay a bare count and 1000 must
    /// become "1k" — an off-by-one here shows up as "1000k" or "0M".
    @Test("unit boundaries scale at the right thresholds")
    func compact_tokens_boundaries() {
        func inputOnly(_ n: Int) -> String {
            CostFooterView.compactTokens(ModelUsage(inputTokens: n))
        }
        #expect(inputOnly(999).hasPrefix("999 in"))
        #expect(inputOnly(1_000).hasPrefix("1k in"))
        #expect(inputOnly(999_499).hasPrefix("999k in"))
        // Just below a million must not render as "1000k": the unit switches
        // where the rounded value would carry, not at the round number.
        #expect(inputOnly(999_999).hasPrefix("1M in"))
        #expect(inputOnly(1_000_000).hasPrefix("1M in"))
        #expect(inputOnly(999_999_999).hasPrefix("1.0B in"))
        #expect(inputOnly(1_000_000_000).hasPrefix("1.0B in"))
    }

    @Test("zero usage still renders both mandatory buckets")
    func compact_tokens_zero() {
        #expect(CostFooterView.compactTokens(ModelUsage()) == "0 in · 0 out")
    }
}
