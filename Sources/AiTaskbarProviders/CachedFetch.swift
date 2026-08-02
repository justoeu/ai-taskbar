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
        if !forceRefresh, let hit = cache.freshPayloadWithAge() {
            return try makeOutcome(from: hit.0, decode: decode,
                                    isStale: false, cacheAge: hit.1,
                                    lastError: nil)
        }
        do {
            let data = try await fetch()
            try Task.checkCancellation()
            try cache.writePayload(data)
            return try makeOutcome(from: data, decode: decode,
                                    isStale: false, cacheAge: 0,
                                    lastError: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch let appErr as AppError {
            // Mark stale for ANY AppError so the UI's stale tooltip can
            // surface why the live fetch failed (credential ACL mismatch,
            // schema drift, transport error, etc.). status = 0 conventionally
            // means "no HTTP response" — distinguishes from 4xx/5xx.
            // Scrub before persisting: `.last_error` is written to disk, and
            // a vendor's 4xx body can echo the account back (user_id, email).
            // The success path has always been scrubbed; this one had not.
            let fe: FetchError
            if case .http(let status, let body) = appErr {
                fe = FetchError(status: status,
                                body: PIIScrub.scrub(diagnostic: body))
            } else {
                fe = FetchError(status: 0,
                                body: PIIScrub.scrub(diagnostic: appErr.description))
            }
            cache.markFailed(fe)
            return try fallback(error: appErr, decode: decode, lastError: fe)
        } catch {
            let fe = FetchError(status: 0,
                                body: PIIScrub.scrub(diagnostic: String(describing: error)))
            cache.markFailed(fe)
            return try fallback(error: error, decode: decode, lastError: fe)
        }
    }

    private func makeOutcome(from data: Data,
                             decode: (Data) throws -> VendorSnapshot,
                             isStale: Bool,
                             cacheAge: TimeInterval?,
                             lastError: FetchError?) throws -> FetchOutcome {
        FetchOutcome(
            snapshot: try decode(data),
            isStale: isStale,
            lastError: lastError ?? cache.lastError(),
            cacheAge: cacheAge
        )
    }

    private func fallback(error: Error,
                          decode: (Data) throws -> VendorSnapshot,
                          lastError: FetchError) throws -> FetchOutcome {
        if let hit = cache.anyPayloadWithAge() {
            return try makeOutcome(from: hit.0, decode: decode,
                                    isStale: true, cacheAge: hit.1,
                                    lastError: lastError)
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
