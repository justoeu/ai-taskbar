import Foundation
import Testing
@testable import AiTaskbarCore

/// `ClaudeSessionScanner.estimate(roots:)`: one `projects/` folder per
/// account (SDD-claude-multi-account §6.5).
@Suite("ClaudeSessionScanner — multiple accounts")
struct ClaudeMultiRootScanTests {
    let base: URL
    let now = Date()

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-claude-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private func line(messageId: String?, requestId: String?, output: Int,
                      model: String = "claude-opus-4-7") -> String {
        let ts = ISO8601DateFormatter().string(from: now)
        let req = requestId.map { #""requestId":"\#($0)","# } ?? ""
        let mid = messageId.map { #""id":"\#($0)","# } ?? ""
        return #"{\#(req)"timestamp":"\#(ts)","message":{\#(mid)"role":"assistant","model":"\#(model)","usage":{"input_tokens":10,"output_tokens":\#(output),"cache_read_input_tokens":0}}}"#
    }

    /// `<base>/<name>/projects/p/s.jsonl` holding `lines`.
    private func root(_ name: String, _ lines: [String]) throws -> ClaudeSessionScanner.Root {
        let projects = base.appendingPathComponent(name).appendingPathComponent("projects")
        let dir = projects.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent("s.jsonl"))
        return .init(key: name, projectsDir: projects)
    }

    private func output(_ estimate: CostEstimate?) -> Int {
        estimate?.totalsByModel["claude-opus-4-7"]?.outputTokens ?? 0
    }

    private func scan(_ roots: [ClaudeSessionScanner.Root]) -> ClaudeSessionScanner.MultiEstimate {
        ClaudeSessionScanner.estimate(now: now, roots: roots, memo: ScanMemo())
    }

    @Test("each account is billed for the transcripts in its own folder")
    func attribution() throws {
        let a = try root("anthropic", [line(messageId: "m1", requestId: "r1", output: 50)])
        let b = try root("anthropic.b", [line(messageId: "m2", requestId: "r2", output: 30)])
        let result = scan([a, b])
        #expect(output(result.byAccount["anthropic"]) == 50)
        #expect(output(result.byAccount["anthropic.b"]) == 30)
        #expect(output(result.total) == 80)
    }

    @Test("the same response in two folders counts once, for the copy with the larger output")
    func cross_root_dedupe() throws {
        let a = try root("anthropic", [line(messageId: "m", requestId: "r", output: 10)])
        let b = try root("anthropic.b", [line(messageId: "m", requestId: "r", output: 40)])
        let result = scan([a, b])
        #expect(output(result.total) == 40)
        #expect(output(result.byAccount["anthropic.b"]) == 40)
        #expect(output(result.byAccount["anthropic"]) == 0)
    }

    @Test("an exact duplicate across folders stays with the earlier root")
    func cross_root_tie() throws {
        let a = try root("anthropic", [line(messageId: "m", requestId: "r", output: 25)])
        let b = try root("anthropic.b", [line(messageId: "m", requestId: "r", output: 25)])
        let result = scan([a, b])
        #expect(output(result.total) == 25)
        #expect(output(result.byAccount["anthropic"]) == 25)
        #expect(output(result.byAccount["anthropic.b"]) == 0)
    }

    @Test("lines without ids are counted in their own folder")
    func unkeyed_lines() throws {
        let a = try root("anthropic", [line(messageId: nil, requestId: nil, output: 7)])
        let b = try root("anthropic.b", [line(messageId: nil, requestId: nil, output: 9)])
        let result = scan([a, b])
        #expect(output(result.byAccount["anthropic"]) == 7)
        #expect(output(result.byAccount["anthropic.b"]) == 9)
        #expect(output(result.total) == 16)
    }

    @Test("an account without a projects folder reads as no sessions, not as a failure")
    func missing_root() throws {
        let a = try root("anthropic", [line(messageId: "m1", requestId: "r1", output: 50)])
        let missing = ClaudeSessionScanner.Root(key: "anthropic.b",
                                                projectsDir: base.appendingPathComponent("nope/projects"))
        let result = scan([a, missing])
        #expect(output(result.total) == 50)
        #expect(result.byAccount["anthropic.b"]?.note == "No recent Claude sessions found.")
    }

    @Test("with every folder missing the total keeps the old note")
    func every_root_missing() {
        let missing = ClaudeSessionScanner.Root(key: "anthropic",
                                                projectsDir: base.appendingPathComponent("nope/projects"))
        #expect(scan([missing]).total.note == "No ~/.claude/projects directory.")
    }

    @Test("the single-folder API is the multi-folder total for one root")
    func single_root_matches() throws {
        let a = try root("anthropic", [line(messageId: "m1", requestId: "r1", output: 50),
                                       line(messageId: nil, requestId: nil, output: 5)])
        let single = ClaudeSessionScanner.estimate(now: now, projectsDir: a.projectsDir, memo: ScanMemo())
        #expect(output(single) == output(scan([a]).total))
        #expect(single.usdLast7Days == scan([a]).total.usdLast7Days)
    }
}
