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
    func writeBack(_ updated: AnthropicCredentials) throws
}
