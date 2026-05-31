import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("AppError classification and wrapping")
struct AppErrorTests {
    @Test("description carries case prefix")
    func description_has_case_prefix() {
        #expect(AppError.io("disk").description.hasPrefix("io:"))
        #expect(AppError.credentials("kc").description.hasPrefix("credentials:"))
        #expect(AppError.transport("net").description.hasPrefix("transport:"))
        #expect(AppError.schema("bad").description.hasPrefix("schema mismatch:"))
        #expect(AppError.toml("parse").description.hasPrefix("toml:"))
        #expect(AppError.disabled("off").description.hasPrefix("disabled:"))
        #expect(AppError.other("x").description == "x")
    }

    @Test("http description truncates body")
    func http_description_truncates_body() {
        let bigBody = String(repeating: "x", count: 500)
        let s = AppError.http(status: 500, body: bigBody).description
        #expect(s.hasPrefix("http 500:"))
        // 200-char prefix means well under the raw 500-char body.
        #expect(s.count < 250)
    }

    @Test("isDisabled flips only on .disabled")
    func isDisabled_flips_only_on_disabled() {
        #expect(AppError.disabled("x").isDisabled)
        #expect(!AppError.io("x").isDisabled)
        #expect(!AppError.transport("x").isDisabled)
        #expect(!AppError.http(status: 401, body: "").isDisabled)
    }

    @Test("isTransient covers transport + retry HTTP codes")
    func isTransient_covers_transport_and_retry_codes() {
        #expect(AppError.transport("x").isTransient)
        #expect(AppError.http(status: 408, body: "").isTransient)
        #expect(AppError.http(status: 429, body: "").isTransient)
        #expect(AppError.http(status: 500, body: "").isTransient)
        #expect(AppError.http(status: 503, body: "").isTransient)
        #expect(AppError.http(status: 599, body: "").isTransient)
        // Not transient
        #expect(!AppError.http(status: 401, body: "").isTransient)
        #expect(!AppError.http(status: 404, body: "").isTransient)
        #expect(!AppError.io("disk").isTransient)
        #expect(!AppError.credentials("x").isTransient)
    }

    @Test("isRateLimited flips only on HTTP 429")
    func isRateLimited_flips_only_on_429() {
        #expect(AppError.http(status: 429, body: "").isRateLimited)
        #expect(!AppError.http(status: 408, body: "").isRateLimited)
        #expect(!AppError.http(status: 500, body: "").isRateLimited)
        #expect(!AppError.http(status: 401, body: "").isRateLimited)
        #expect(!AppError.transport("net").isRateLimited)
        #expect(!AppError.io("disk").isRateLimited)
    }

    @Test("errorDescription mirrors description")
    func errorDescription_mirrors_description() {
        let err = AppError.schema("bad")
        #expect(err.errorDescription == err.description)
    }

    @Test("wrapping passes through existing AppError")
    func wrapping_passes_through_appError() {
        let inner = AppError.transport("a")
        let wrapped = AppError.wrapping(inner)
        #expect(wrapped == inner)
    }

    @Test("wrapping converts arbitrary Error to .other")
    func wrapping_converts_unknown_error() {
        struct OddError: Error { let label: String }
        let wrapped = AppError.wrapping(OddError(label: "boom"))
        // .other carries the string form
        if case .other(let s) = wrapped {
            #expect(s.contains("OddError"))
        } else {
            Issue.record("expected .other case")
        }
    }

    @Test("Equatable distinguishes cases and payloads")
    func equatable_distinguishes_cases_and_payloads() {
        #expect(AppError.io("a") == AppError.io("a"))
        #expect(AppError.io("a") != AppError.io("b"))
        #expect(AppError.io("a") != AppError.transport("a"))
        #expect(AppError.http(status: 500, body: "x") == AppError.http(status: 500, body: "x"))
        #expect(AppError.http(status: 500, body: "x") != AppError.http(status: 500, body: "y"))
    }
}
