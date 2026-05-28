import XCTest
@testable import AiTaskbarApp

final class SmokeTests: XCTestCase {
    func test_app_module_loads() {
        // Compile-only smoke. Real UI testing would need ViewInspector or
        // pointfreeco/swift-snapshot-testing — deferred to v2.
        XCTAssertTrue(true)
    }
}
