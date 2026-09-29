import Testing
import Foundation
@testable import AiTaskbarCore
import AiTaskbarTesting

@Suite("OffPool")
struct OffPoolTests {
    @Test("OffPool.run executes on a GCD thread, not the cooperative pool")
    func offpool_leaves_cooperative_pool() async throws {
        let onPool = try await OffPool.run { CooperativePoolProbe.isOnCooperativePool }
        let detachedOnPool = await Task.detached { CooperativePoolProbe.isOnCooperativePool }.value
        #expect(!onPool)
        #expect(detachedOnPool)
    }

    @Test("OffPool.run rethrows the body's error")
    func offpool_rethrows() async {
        await #expect(throws: AppError.self) {
            try await OffPool.run { () throws -> Int in throw AppError.credentials("x") }
        }
    }
}
