import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("SessionCounters")
struct SessionCountersTests {
    @Test("antigravityCount returns correct number of recent db files")
    func antigravity_count() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-antigravity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let now = Date()
        let oldDate = now.addingTimeInterval(-100_000)
        let recentDate = now.addingTimeInterval(-1_000)

        let db1 = tempDir.appendingPathComponent("conv1.db")
        let db2 = tempDir.appendingPathComponent("conv2.db")
        let txt = tempDir.appendingPathComponent("ignore.txt")

        try Data("dummy1".utf8).write(to: db1)
        try Data("dummy2".utf8).write(to: db2)
        try Data("dummy3".utf8).write(to: txt)

        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: db1.path)
        try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: db2.path)

        let sinceDate = now.addingTimeInterval(-50_000)
        let count = SessionCounters.antigravityCount(since: sinceDate, directory: tempDir)
        #expect(count == 1)

        let allCount = SessionCounters.antigravityCount(since: now.addingTimeInterval(-200_000), directory: tempDir)
        #expect(allCount == 2)
    }

    @Test("grokCount returns correct number of recent directories")
    func grok_count() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-grok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let now = Date()
        let oldDate = now.addingTimeInterval(-100_000)
        let recentDate = now.addingTimeInterval(-1_000)

        let sess1 = tempDir.appendingPathComponent("sess1")
        let sess2 = tempDir.appendingPathComponent("sess2")

        try FileManager.default.createDirectory(at: sess1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sess2, withIntermediateDirectories: true)

        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: sess1.path)
        try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: sess2.path)

        let sinceDate = now.addingTimeInterval(-50_000)
        let count = SessionCounters.grokCount(since: sinceDate, directory: tempDir)
        #expect(count == 1)
    }

    @Test("nonexistent directory returns 0")
    func nonexistent_directory() {
        let fake = URL(fileURLWithPath: "/tmp/nonexistent-sessions-\(UUID().uuidString)")
        #expect(SessionCounters.antigravityCount(since: Date(), directory: fake) == 0)
        #expect(SessionCounters.grokCount(since: Date(), directory: fake) == 0)
    }
}
