import Foundation
import Darwin
import AiTaskbarCore

/// Contains only account identity and an idempotency key, never credentials.
/// Kept until a definitive outcome so a restart cannot create a second attempt.
struct OpenAIResetJournal: Sendable {
    let path: URL

    init(path: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/ai-taskbar/openai-reset-attempt.json")) {
        self.path = path
    }

    func read() throws -> OpenAIResetOffer? {
        do {
            var offer = try SharedCoders.decoder.decode(OpenAIResetOffer.self, from: Data(contentsOf: path))
            guard !offer.accountID.isEmpty else { throw OpenAIResetError.protocolFailure }
            offer.isRetry = true
            return offer
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(_ offer: OpenAIResetOffer) throws {
        if let existing = try read(), existing.id != offer.id || existing.accountID != offer.accountID {
            throw OpenAIResetError.attemptInProgress
        }
        try AtomicFileWrite.write(SharedCoders.encoder.encode(offer), to: path, permissions: 0o600)
    }

    /// A fixed sibling lock survives journal replacement. Hold across identity
    /// check, persistence, RPC dispatch and clear, including other app instances.
    func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        try Paths.ensureDir(path.deletingLastPathComponent())
        let fd = Darwin.open(path.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw OpenAIResetError.protocolFailure }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw OpenAIResetError.attemptInProgress }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    func clear() throws {
        try FileManager.default.removeItem(at: path)
    }

    /// A rejection today cannot prove that yesterday's ambiguous dispatch was
    /// rejected. Only a genuinely new, explicitly rejected consume may be cleared.
    func rejectUnsupported(isRetry: Bool) throws -> Never {
        if isRetry { throw OpenAIResetError.submissionUncertain }
        try clear()
        throw OpenAIResetError.consumeUnsupported
    }
}
