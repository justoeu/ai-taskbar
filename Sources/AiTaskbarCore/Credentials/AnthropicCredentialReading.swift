import Foundation

/// Read/write surface for Anthropic OAuth credentials. The production
/// implementation is `KeychainCredentialReader` (macOS Login Keychain); test
/// targets supply lightweight in-memory mocks.
///
/// Why a protocol vs the original concrete class:
/// dependency-inverting the credential surface lets `KeychainCredentialReader`
/// stay `final` (no production subclassing) while tests still get a swap
/// point. The previous design relied on subclassing the concrete reader —
/// fine in practice (the module isn't a public library) but a worse
/// security posture if anything ever consumes `AiTaskbarCore` externally.
public protocol AnthropicCredentialReading: Sendable {
    func read() throws -> AnthropicCredentials
    /// User-initiated durable authorization of this signed app against the
    /// backing Keychain item. Returns `.canceled` when the native macOS
    /// password dialog is dismissed without changing the ACL.
    func authorizePersistently() throws -> KeychainAccessAuthorizer.Outcome
    /// Drops process-memory credentials after the usage API rejects them.
    /// The next `read()` must consult the backing credential source again.
    func invalidateCachedCredentials()
    func writeBack(_ updated: AnthropicCredentials) throws
}

public extension AnthropicCredentialReading {
    /// `read()` may block for up to `SecurityToolCredentialReader.defaultTimeout`
    /// while the `/usr/bin/security` fallback runs. Async callers hop onto a
    /// plain GCD thread so a hung tool parks neither the main actor nor one
    /// of the cooperative pool's few worker threads.
    func readOffPool() async throws -> AnthropicCredentials {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.read() })
            }
        }
    }

    /// Test/in-memory readers need no distinct persistent-ACL path.
    func authorizePersistently() throws -> KeychainAccessAuthorizer.Outcome {
        _ = try read()
        return .authorized
    }
    func invalidateCachedCredentials() {}
}
