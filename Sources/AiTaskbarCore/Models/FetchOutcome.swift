import Foundation

public struct FetchError: Sendable, Equatable, Codable {
    public let status: Int
    /// English diagnostic, for logs and `.last_error`. Not user-facing text.
    public let body: String
    /// Set when the failure was an `AppError.guidance`, so the UI can render
    /// the localized guidance instead of `body`'s "guidance: …" diagnostic.
    /// In memory only: `DiskCache.lastError()` does not persist it. That is
    /// safe because guidance is rendered only by the stale tooltip, and a
    /// stale outcome always carries the in-memory error of the failure that
    /// made it stale; a cache hit that reads the persisted error is never
    /// stale. `CachedFetchEdgeTests` pins both halves (CQ-MAE-015).
    public let guidance: VendorGuidance?
    public init(status: Int, body: String, guidance: VendorGuidance? = nil) {
        self.status = status
        self.body = body
        self.guidance = guidance
    }
}

public struct CachedOutcome<Snapshot: Sendable & Equatable>: Sendable, Equatable {
    public let snapshot: Snapshot
    /// True when the snapshot came from cache because a live fetch failed.
    public let isStale: Bool
    public let lastError: FetchError?
    public let cacheAge: TimeInterval?
    public let fetchedAt: Date

    public init(snapshot: Snapshot,
                isStale: Bool = false,
                lastError: FetchError? = nil,
                cacheAge: TimeInterval? = nil,
                fetchedAt: Date = .init()) {
        self.snapshot = snapshot
        self.isStale = isStale
        self.lastError = lastError
        self.cacheAge = cacheAge
        self.fetchedAt = fetchedAt
    }
}

public typealias FetchOutcome = CachedOutcome<VendorSnapshot>
public typealias ServiceStatusOutcome = CachedOutcome<VendorServiceStatus>
