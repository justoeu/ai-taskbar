import Foundation
import AiTaskbarCore

public protocol UsageProvider: Sendable {
    var vendorId: VendorId { get }
    var displayName: String { get }
    /// Fetches a snapshot. If `forceRefresh` is false and the disk cache is
    /// fresh, returns the cached snapshot without a network call. On network
    /// failure, falls back to a stale cached snapshot when available.
    func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome
    /// Optional user-initiated credential authorization. Providers without a
    /// foreign interactive credential surface use the default unsupported
    /// implementation.
    func authorizeCredentialsInteractively() throws
    /// Filesystem path of the file-backed credential backing this provider,
    /// if any. Watched by the UI so a re-login performed externally (e.g.
    /// `codex login` run by the user) triggers an immediate refresh instead
    /// of waiting for the next scheduled tick. nil for providers whose
    /// credentials live in the Keychain or an env var.
    var credentialFileURL: URL? { get }
}

public extension UsageProvider {
    var displayName: String { vendorId.displayName }
    var credentialFileURL: URL? { nil }
    func authorizeCredentialsInteractively() throws {
        throw AppError.credentials("Interactive credential authorization is not supported for \(displayName)")
    }
}
