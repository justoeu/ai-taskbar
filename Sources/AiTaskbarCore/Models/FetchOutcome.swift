import Foundation

public struct FetchError: Sendable, Equatable, Codable {
    public let status: Int
    public let body: String
    public init(status: Int, body: String) {
        self.status = status
        self.body = body
    }
}

public struct FetchOutcome: Sendable, Equatable {
    public let snapshot: VendorSnapshot
    /// True when the snapshot came from cache because a live fetch failed.
    public let isStale: Bool
    public let lastError: FetchError?
    public let cacheAge: TimeInterval?
    public let fetchedAt: Date

    public init(snapshot: VendorSnapshot,
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
