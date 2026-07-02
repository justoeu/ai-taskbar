import Foundation
import Testing
@testable import AiTaskbarCore

@Suite("UsageWindow.isAwaitingReset")
struct UsageWindowResetTests {
    private func window(resetsAt: Date?) -> UsageWindow {
        UsageWindow(label: "Session 5h", utilizationPercent: 42, resetsAt: resetsAt)
    }

    @Test("future reset is still counting down")
    func future_reset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let w = window(resetsAt: now.addingTimeInterval(60))
        #expect(w.isAwaitingReset(now: now) == false)
    }

    @Test("past reset awaits refresh")
    func past_reset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let w = window(resetsAt: now.addingTimeInterval(-1))
        #expect(w.isAwaitingReset(now: now) == true)
    }

    @Test("reset exactly now awaits refresh")
    func boundary_reset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let w = window(resetsAt: now)
        #expect(w.isAwaitingReset(now: now) == true)
    }

    @Test("nil resetsAt never awaits")
    func nil_reset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(window(resetsAt: nil).isAwaitingReset(now: now) == false)
    }
}
