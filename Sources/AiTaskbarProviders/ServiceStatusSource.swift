import Foundation
import AiTaskbarCore

/// Adapter boundary used by ``CachedServiceStatusProvider``. A source owns
/// only wire fetching and conversion; the shared provider owns cache policy.
public protocol ServiceStatusSource: Sendable {
    associatedtype Payload: Codable & Sendable

    var vendorId: VendorId { get }

    func fetchPayload(http: HTTPClient, now: Date) async throws -> Payload
    func makeStatus(from payload: Payload, now: Date) throws -> VendorServiceStatus
}
