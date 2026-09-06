import Foundation
import Testing
import AiTaskbarCore
import AiTaskbarTestSupport
@testable import AiTaskbarApp

@Suite("OpenAI reset durable attempt")
struct OpenAIResetJournalTests {
    @Test("restart keeps key and account; conflicting attempts cannot overwrite it")
    func durable_and_exclusive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = OpenAIResetJournal(path: directory.appendingPathComponent("attempt.json"))
        let offer = OpenAIResetOffer(accountID: "A", accountLabel: "A", availableCount: 1)
        expectTrue(try journal.read() == nil)
        try journal.withExclusiveAccess {
            try journal.save(offer)
            #expect(throws: OpenAIResetError.attemptInProgress) {
                try journal.withExclusiveAccess { }
            }
        }
        let restored = try #require(try journal.read())
        #expect(restored.id == offer.id)
        #expect(restored.accountID == "A")
        expectTrue(restored.isRetry)
        let attributes = try FileManager.default.attributesOfItem(atPath: journal.path.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        let conflict = OpenAIResetOffer(accountID: "A", accountLabel: "A", availableCount: 1)
        #expect(throws: OpenAIResetError.attemptInProgress) { try journal.save(conflict) }
        expectTrue(try journal.read()?.id == offer.id)
        try journal.clear()
        expectTrue(try journal.read() == nil)
    }

    @Test("corrupt journal fails closed without silently forgetting an attempt")
    func corrupt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = OpenAIResetJournal(path: directory.appendingPathComponent("attempt.json"))
        try AtomicFileWrite.write(Data("invalid".utf8), to: journal.path, permissions: 0o600)
        #expect(throws: (any Error).self) { try journal.read() }
        #expect(throws: (any Error).self) {
            try journal.save(OpenAIResetOffer(accountID: "A", accountLabel: "A", availableCount: 1))
        }
    }

    @Test("method rejection only clears a new attempt, never a prior ambiguous reset")
    func unsupported_rejection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = OpenAIResetJournal(path: directory.appendingPathComponent("attempt.json"))
        let offer = OpenAIResetOffer(accountID: "A", accountLabel: "A", availableCount: 1)
        try journal.save(offer)
        #expect(throws: OpenAIResetError.submissionUncertain) { try journal.rejectUnsupported(isRetry: true) }
        expectTrue(try journal.read()?.id == offer.id)
        #expect(throws: OpenAIResetError.consumeUnsupported) { try journal.rejectUnsupported(isRetry: false) }
        expectTrue(try journal.read() == nil)
    }
}
