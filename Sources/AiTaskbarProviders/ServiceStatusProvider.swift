import Foundation
import AiTaskbarCore

/// Public operational-status contract. Service status is deliberately
/// independent from authenticated usage collection.
public protocol ServiceStatusProvider: Sendable {
    var vendorId: VendorId { get }

    func fetchStatus(
        forceRefresh: Bool,
        now: Date
    ) async throws -> ServiceStatusOutcome
}

public extension ServiceStatusProvider {
    func fetchStatus(forceRefresh: Bool) async throws -> ServiceStatusOutcome {
        try await fetchStatus(forceRefresh: forceRefresh, now: .now)
    }
}
