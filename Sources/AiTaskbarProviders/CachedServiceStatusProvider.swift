import Foundation
import AiTaskbarCore

/// Generic cache lifecycle for public service-status adapters. The source's
/// combined Codable payload is persisted, then converted with an explicit
/// `now` so the six-hour window remains deterministic in tests.
public struct CachedServiceStatusProvider<Source: ServiceStatusSource>:
    ServiceStatusProvider, Sendable
{
    public let source: Source
    public let fetcher: CachedFetch
    public let http: HTTPClient

    public var vendorId: VendorId { source.vendorId }

    public init(source: Source, cache: DiskCache, http: HTTPClient) {
        self.source = source
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
    }

    public init(
        source: Source,
        http: HTTPClient = .init(),
        cacheTTL: TimeInterval = 300
    ) throws {
        let cache = try DiskCache.defaultFor(
            source.vendorId,
            scope: .status,
            ttl: cacheTTL
        )
        self.init(source: source, cache: cache, http: http)
    }

    public func fetchStatus(
        forceRefresh: Bool,
        now: Date
    ) async throws -> ServiceStatusOutcome {
        try await fetcher.run(
            forceRefresh: forceRefresh,
            decode: { data in
                do {
                    let payload = try SharedCoders.decoder.decode(Source.Payload.self, from: data)
                    return try source.makeStatus(from: payload, now: now)
                } catch let error as AppError {
                    throw error
                } catch {
                    throw AppError.schema("service status cache decode: \(error)")
                }
            },
            fetch: {
                let payload = try await source.fetchPayload(http: http, now: now)
                try Task.checkCancellation()
                do {
                    return try SharedCoders.encoder.encode(payload)
                } catch {
                    throw AppError.schema("service status cache encode: \(error)")
                }
            }
        )
    }
}
