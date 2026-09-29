import Testing
import Foundation
@testable import AiTaskbarCore

private func b64url(_ s: String) -> String {
    Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func token(payload: String) -> String {
    "\(b64url(#"{"alg":"none"}"#)).\(b64url(payload))."
}

/// Credential files, JWT claims and persisted history are external input:
/// any finite Double they carry must convert to an integer without trapping
/// (B3-numeric: BEST-ATE-003, BUG-CET-001, SEC-CER-002/004).
@Suite("Numeric conversion traps — credentials, JWT, history", .serialized)
struct NumericConversionTrapTests {
    @Test("JWT Int claim of 1e300 is not representable → nil, not a trap")
    func jwt_huge_int_claim_is_nil() {
        let t = token(payload: #"{"n":1e300}"#)
        expectTrue(JWT.claim(t, key: "n", as: Int.self) == nil)
    }

    @Test("JWT Int64 claim of -1e300 is not representable → nil, not a trap")
    func jwt_huge_int64_claim_is_nil() {
        let t = token(payload: #"{"n":-1e300}"#)
        expectTrue(JWT.claim(t, key: "n", as: Int64.self) == nil)
    }

    @Test("JWT fractional Int claim still truncates as before")
    func jwt_fractional_int_claim_truncates() {
        let t = token(payload: #"{"n":42.9}"#)
        #expect(JWT.claim(t, key: "n", as: Int.self) == 42)
    }

    @Test("Anthropic credential expiresAt 1e300 saturates instead of trapping")
    func anthropic_credentials_huge_expiry_saturates() throws {
        let json = #"{"accessToken":"a","refreshToken":"r","expiresAt":1e300}"#
        let creds = try JSONDecoder().decode(AnthropicCredentials.self, from: Data(json.utf8))
        #expect(creds.expiresAtMs == Int64.max)
    }

    @Test("Anthropic credential fractional expiresAt still truncates")
    func anthropic_credentials_fractional_expiry_truncates() throws {
        let json = #"{"accessToken":"a","refreshToken":"r","expiresAt":1700000000000.7}"#
        let creds = try JSONDecoder().decode(AnthropicCredentials.self, from: Data(json.utf8))
        #expect(creds.expiresAtMs == 1_700_000_000_000)
    }

    @Test("Anthropic rotated() with an absurd expires_in saturates instead of trapping")
    func anthropic_rotated_huge_expiry_saturates() {
        let creds = AnthropicCredentials(accessToken: "a", refreshToken: "r", expiresAtMs: 1)
        let rotated = creds.rotated(accessToken: "b", refreshToken: nil,
                                    expiresAt: Date(timeIntervalSince1970: 1e300))
        #expect(rotated.expiresAtMs == Int64.max)
    }

    @Test("Codex reconciliation with a JWT exp of 1e300 does not trap; huge exp is freshest")
    func codex_reconciliation_huge_exp() {
        let huge = CodexAuth(tokens: CodexTokens(accessToken: "p", refreshToken: "r",
                                                 idToken: token(payload: #"{"exp":1e300}"#)))
        let normal = CodexAuth(tokens: CodexTokens(accessToken: "d", refreshToken: "r",
                                                   idToken: token(payload: #"{"exp":1000}"#)))
        let v = CodexReconciliation.pick(disk: normal, pending: huge)
        #expect(v?.credentials == huge)
    }

    @Test("UsageWindow clamps a non-finite / absurd utilization at init")
    func usage_window_sanitizes_init() {
        #expect(UsageWindow(label: "x", utilizationPercent: 1e300).utilizationPercent == 1000)
        #expect(UsageWindow(label: "x", utilizationPercent: .nan).utilizationPercent == 0)
        #expect(UsageWindow(label: "x", utilizationPercent: 47.2).utilizationPercent == 47.2)
    }

    @Test("UsageWindow clamps a cached (decoded) absurd utilization")
    func usage_window_sanitizes_decode() throws {
        let json = #"{"label":"x","utilizationPercent":1e300}"#
        let w = try JSONDecoder().decode(UsageWindow.self, from: Data(json.utf8))
        #expect(w.utilizationPercent == 1000)
    }

    @Test("ModelShare replaces a NaN / absurd percent, also when decoded from cache")
    func model_share_sanitizes() throws {
        #expect(ModelShare(model: "m", percent: .nan, rawUsage: 1).percent == 0)
        let json = #"{"model":"m","percent":1e300,"rawUsage":1}"#
        let s = try JSONDecoder().decode(ModelShare.self, from: Data(json.utf8))
        #expect(s.percent == 1000)
    }

    @Test("UsageHistoryStore never persists / replays an absurd utilization")
    func history_sanitizes_append_and_load() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-numeric-\(UUID().uuidString)")
        try Paths.ensureDir(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageHistoryStore(vendor: .anthropic, baseDir: dir)
        // A line an older build already wrote to disk.
        try Data(#"{"at":1700000000,"max":1e300}"#.utf8 + [0x0a])
            .write(to: store.fileURL)
        store.append(maxUtilization: .infinity, at: Date(timeIntervalSince1970: 1_700_000_100))
        let samples = store.load(since: Date(timeIntervalSince1970: 0))
        #expect(samples.map(\.max) == [1000, 1000])
    }
}

@Suite("SafeNumeric — non-trapping Double to integer conversion")
struct SafeNumericTests {
    @Test("saturating: NaN is 0")
    func saturating_nan() { #expect(Int(saturating: .nan) == 0) }

    @Test("saturating: +inf clamps to .max")
    func saturating_positive_infinity() { #expect(Int(saturating: .infinity) == Int.max) }

    @Test("saturating: 1e300 clamps to Int64.max")
    func saturating_positive_overflow() { #expect(Int64(saturating: 1e300) == Int64.max) }

    @Test("saturating: 2^63 (Double(Int.max)) is .max, not a trap")
    func saturating_exact_boundary() { #expect(Int(saturating: Double(Int.max)) == Int.max) }

    @Test("saturating: -inf clamps to .min")
    func saturating_negative_infinity() { #expect(Int(saturating: -.infinity) == Int.min) }

    @Test("saturating: narrow type negative overflow clamps to .min")
    func saturating_narrow_negative_overflow() { #expect(Int32(saturating: -1e10) == Int32.min) }

    @Test("saturating: in-range positive truncates toward zero like Int(_:)")
    func saturating_truncates_positive() { #expect(Int(saturating: 84.9) == 84) }

    @Test("saturating: in-range negative truncates toward zero like Int(_:)")
    func saturating_truncates_negative() { #expect(Int(saturating: -2.7) == -2) }

    @Test("saturating: unsigned negative clamps to 0")
    func saturating_unsigned() { #expect(UInt64(saturating: -5) == 0) }

    @Test("checked: NaN is nil")
    func checked_nan() { expectTrue(Int(checkedTruncating: .nan) == nil) }

    @Test("checked: infinity is nil")
    func checked_infinity() { expectTrue(Int(checkedTruncating: .infinity) == nil) }

    @Test("checked: out-of-range is nil")
    func checked_out_of_range() { expectTrue(Int64(checkedTruncating: 1e19) == nil) }

    @Test("checked: in-range positive truncates toward zero")
    func checked_truncates_positive() { #expect(Int(checkedTruncating: 5.99) == 5) }

    @Test("checked: in-range negative truncates toward zero")
    func checked_truncates_negative() { #expect(Int(checkedTruncating: -5.99) == -5) }

    @Test("UtilizationPercent: NaN is 0")
    func utilization_nan() { #expect(UtilizationPercent.sanitized(.nan) == 0) }

    @Test("UtilizationPercent: negative clamps to 0")
    func utilization_negative() { #expect(UtilizationPercent.sanitized(-3) == 0) }

    @Test("UtilizationPercent: infinity clamps to the documented maximum")
    func utilization_infinity() {
        #expect(UtilizationPercent.sanitized(.infinity) == UtilizationPercent.maximum)
    }

    @Test("UtilizationPercent: maximum is 1000 %")
    func utilization_maximum_value() { #expect(UtilizationPercent.maximum == 1000) }

    @Test("UtilizationPercent: normal reading unchanged")
    func utilization_normal() { #expect(UtilizationPercent.sanitized(47.2) == 47.2) }

    @Test("UtilizationPercent: vendor-reported overuse unchanged")
    func utilization_overuse() { #expect(UtilizationPercent.sanitized(137.5) == 137.5) }
}
