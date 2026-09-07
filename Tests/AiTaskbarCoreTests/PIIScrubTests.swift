import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("PIIScrub")
struct PIIScrubTests {
    @Test("strips sensitive keys at the top level")
    func strips_top_level() throws {
        let raw = Data(#"{"user_id":"u1","email":"a@b.com","plan_type":"pro"}"#.utf8)
        let out = String(data: PIIScrub.scrub(bytes: raw), encoding: .utf8) ?? ""
        expectFalse(out.contains("user_id"))
        expectFalse(out.contains("a@b.com"))
        expectTrue(out.contains("plan_type"))
    }

    /// Nesting is the case the original implementation was written to handle;
    /// keep it pinned when the logic moved to a shared type.
    @Test("strips sensitive keys at every depth, including inside arrays")
    func strips_nested() throws {
        let raw = Data(#"{"data":{"account_id":"a1","items":[{"email":"x@y.z","n":1}]}}"#.utf8)
        let out = String(data: PIIScrub.scrub(bytes: raw), encoding: .utf8) ?? ""
        expectFalse(out.contains("account_id"))
        expectFalse(out.contains("x@y.z"))
        expectTrue(out.contains("\"n\""))
    }

    @Test("non-object JSON passes through byte-identical")
    func non_object_passthrough() {
        let raw = Data("[1,2,3]".utf8)
        #expect(PIIScrub.scrub(bytes: raw) == raw)
    }

    /// Error bodies are not always JSON — a gateway can return HTML or a bare
    /// sentence — so JSON scrubbing alone would let an address through.
    @Test("redacts emails in non-JSON diagnostics")
    func redacts_plain_text_email() {
        let out = PIIScrub.scrub(diagnostic: "403 for user justo.eu+tag@example.co.uk on host")
        expectFalse(out.contains("@example.co.uk"))
        expectTrue(out.contains("<redacted-email>"))
        expectTrue(out.contains("403"))
    }

    @Test("caps runaway diagnostics")
    func caps_length() {
        let out = PIIScrub.scrub(diagnostic: String(repeating: "x", count: 10_000))
        expectTrue(out.count < 2_200)
        expectTrue(out.hasSuffix("(truncated)"))
    }

    @Test("JSON diagnostic gets keys stripped, not just emails")
    func json_diagnostic_scrubbed() {
        let out = PIIScrub.scrub(diagnostic: #"{"error":"nope","user_id":"u1"}"#)
        expectFalse(out.contains("user_id"))
        expectTrue(out.contains("nope"))
    }
}
