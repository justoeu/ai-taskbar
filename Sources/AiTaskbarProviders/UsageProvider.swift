import Foundation
import AiTaskbarCore

public protocol UsageProvider: Sendable {
    var vendorId: VendorId { get }
    var displayName: String { get }
    /// Fetches a snapshot. If `forceRefresh` is false and the disk cache is
    /// fresh, returns the cached snapshot without a network call. On network
    /// failure, falls back to a stale cached snapshot when available.
    func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome
}

public extension UsageProvider {
    var displayName: String { vendorId.displayName }
}
