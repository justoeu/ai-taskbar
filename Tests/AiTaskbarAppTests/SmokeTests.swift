import Testing
@testable import AiTaskbarApp

@Suite("AiTaskbarApp smoke")
struct SmokeTests {
    @Test("app module loads")
    func app_module_loads() {
        // Compile-only smoke. Real UI testing would need swift-snapshot-testing
        // or a hosted XCTest target — deferred.
        #expect(Bool(true))
    }
}
