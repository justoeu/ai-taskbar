import Testing
@testable import AiTaskbarCore

@Suite("Semver comparison")
struct SemverTests {
    @Test("strict major/minor/patch bumps")
    func strict_bumps() {
        #expect(Semver.isNewer("v0.2.0", than: "v0.1.0"))
        #expect(Semver.isNewer("0.1.1", than: "0.1.0"))
        #expect(Semver.isNewer("1.0.0", than: "0.99.99"))
    }

    @Test("equal is not newer")
    func equal_is_not_newer() {
        #expect(!Semver.isNewer("v0.1.0", than: "v0.1.0"))
        #expect(!Semver.isNewer("v0.1.0-beta1", than: "v0.1.0-beta1"))
    }

    @Test("older is not newer")
    func older_is_not_newer() {
        #expect(!Semver.isNewer("v0.0.9", than: "v0.1.0"))
        #expect(!Semver.isNewer("0.1.0", than: "0.1.1"))
    }

    @Test("stable beats prerelease of same base")
    func stable_beats_prerelease() {
        #expect(Semver.isNewer("v0.1.0", than: "v0.1.0-beta1"))
        #expect(!Semver.isNewer("v0.1.0-beta1", than: "v0.1.0"))
    }

    @Test("later prerelease tag wins")
    func later_prerelease_wins() {
        #expect(Semver.isNewer("v0.1.0-beta2", than: "v0.1.0-beta1"))
        #expect(Semver.isNewer("v0.1.0-rc.2", than: "v0.1.0-rc.1"))
    }

    @Test("missing patch defaults to zero")
    func missing_patch_defaults_zero() {
        #expect(!Semver.isNewer("v0.2", than: "v0.2.0"))
        #expect(Semver.isNewer("v0.3", than: "v0.2.99"))
    }

    @Test("accepts both v-prefix and bare")
    func accepts_both_v_prefix_and_bare() {
        #expect(Semver.isNewer("0.2.0", than: "v0.1.0"))
        #expect(Semver.isNewer("V0.2.0", than: "0.1.0"))
    }

    @Test("non-numeric components default to zero")
    func non_numeric_components_default_zero() {
        // "v0.x.0" → parts [0, 0, 0]; "v0.0.0" → parts [0, 0, 0]
        // Equal at the numeric level — neither newer.
        #expect(!Semver.isNewer("v0.x.0", than: "v0.0.0"))
    }

    // BUG-ART-012: SemVer 2.0 section 11 prerelease precedence.
    @Test("numeric run in a prerelease compares as an integer (beta10 > beta9)")
    func numeric_run_beta10_beats_beta9() {
        #expect(Semver.isNewer("v0.24.0-beta10", than: "v0.24.0-beta9"))
    }

    @Test("beta9 is not newer than beta10")
    func numeric_run_beta9_not_newer() {
        #expect(!Semver.isNewer("v0.24.0-beta9", than: "v0.24.0-beta10"))
    }

    @Test("dot-separated numeric identifier compares as an integer (rc.10 > rc.9)")
    func dotted_numeric_rc10_beats_rc9() {
        #expect(Semver.isNewer("1.0.0-rc.10", than: "1.0.0-rc.9"))
    }

    @Test("a larger set of identifiers wins when all preceding ones are equal")
    func longer_identifier_list_wins() {
        #expect(Semver.isNewer("1.0.0-alpha.1", than: "1.0.0-alpha"))
    }

    @Test("numeric identifiers have lower precedence than alphanumeric ones")
    func numeric_below_alphanumeric() {
        #expect(Semver.isNewer("1.0.0-alpha", than: "1.0.0-1"))
    }

    @Test("alphanumeric identifiers compare in ASCII order")
    func alphanumeric_ascii_order() {
        #expect(Semver.isNewer("1.0.0-beta", than: "1.0.0-alpha.beta"))
    }

    @Test("equal multi-digit prerelease is not newer")
    func equal_multi_digit_not_newer() {
        #expect(!Semver.isNewer("v0.24.0-beta10", than: "v0.24.0-beta10"))
    }
}
