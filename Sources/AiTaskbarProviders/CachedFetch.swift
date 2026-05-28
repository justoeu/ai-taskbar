import Foundation
import AiTaskbarCore

/// Common cached-fetch lifecycle shared by all providers. Handles cache
/// freshness, stale fallback, cancellation, and turning HTTP errors into
/// `markStale`. Each provider only writes its vendor-specific HTTP work + a
/// decode closure.
///
/// Eliminates ~70 LOC of duplicated `fetchUsage` / `outcome` / `fallbackOrThrow`
/// boilerplate that used to live in every provider.
public struct CachedFetch: Sendable {
    public let cache: DiskCache

    public init(cache: DiskCache) { self.cache = cache }

    /// `fetch` performs the network work and returns the raw payload bytes
    /// that will be cached. It should throw `AppError.http(...)` on non-2xx
    /// responses (the helper will then mark the cache stale automatically).
    /// `decode` turns the cached bytes into a `VendorSnapshot`.
    public func run(
        forceRefresh: Bool,
        decode: (Data) throws -> VendorSnapshot,
        fetch: () async throws -> Data
    ) async throws -> FetchOutcome {
        try Task.checkCancellation()
        if !forceRefresh, let cached = cache.freshPayload() {
            return try makeOutcome(from: cached, decode: decode,
                                    isStale: false, cacheAge: cache.payloadAge())
        }
        do {
            let data = try await fetch()
            try Task.checkCancellation()
            try cache.writePayload(data)
            return try makeOutcome(from: data, decode: decode,
                                    isStale: false, cacheAge: 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch let appErr as AppError {
            // Mark stale for ANY AppError so the UI's stale tooltip can
            // surface why the live fetch failed (credential ACL mismatch,
            // schema drift, transport error, etc.). status = 0 conventionally
            // means "no HTTP response" — distinguishes from 4xx/5xx.
            if case .http(let status, let body) = appErr {
                cache.markFailed(FetchError(status: status, body: body))
            } else {
                cache.markFailed(FetchError(status: 0, body: appErr.description))
            }
            return try fallback(error: appErr, decode: decode)
        } catch {
            cache.markFailed(FetchError(status: 0, body: String(describing: error)))
            return try fallback(error: error, decode: decode)
        }
    }

    private func makeOutcome(from data: Data,
                             decode: (Data) throws -> VendorSnapshot,
                             isStale: Bool, cacheAge: TimeInterval?) throws -> FetchOutcome {
        FetchOutcome(
            snapshot: try decode(data),
            isStale: isStale,
            lastError: cache.lastError(),
            cacheAge: cacheAge
        )
    }

    private func fallback(error: Error,
                          decode: (Data) throws -> VendorSnapshot) throws -> FetchOutcome {
        if let data = cache.anyPayload() {
            return try makeOutcome(from: data, decode: decode,
                                    isStale: true, cacheAge: cache.payloadAge())
        }
        throw AppError.wrapping(error)
    }
}

/// Convenience: send a request, validate 2xx, return bytes.
public extension HTTPClient {
    func fetchPayload(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data.prefix(1024), encoding: .utf8) ?? ""
            throw AppError.http(status: response.statusCode, body: body)
        }
        return data
    }
}
