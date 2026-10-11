import Testing
import Foundation
@testable import AiTaskbarCore

@Suite("ScanMemo — replay vs invalidation")
struct ScanMemoTests {
    private func entry(size: Int, mtime: Date, day: Date) -> ScanMemo.Entry {
        ScanMemo.Entry(size: size, mtime: mtime, computedForDay: day,
                       today: ["m": ModelUsage(inputTokens: 1)],
                       week: ["m": ModelUsage(inputTokens: 2)])
    }

    @Test("identical size + mtime + day replays")
    func replays_when_unchanged() {
        let m = ScanMemo(); let t = Date(timeIntervalSince1970: 1_000); let d = Date(timeIntervalSince1970: 0)
        m.store(path: "/a", entry: entry(size: 10, mtime: t, day: d))
        #expect(m.lookup(path: "/a", size: 10, mtime: t, day: d) != nil)
    }

    /// An append changes size. Missing this would under-report new usage.
    @Test("size change invalidates")
    func size_change_invalidates() {
        let m = ScanMemo(); let t = Date(timeIntervalSince1970: 1_000); let d = Date(timeIntervalSince1970: 0)
        m.store(path: "/a", entry: entry(size: 10, mtime: t, day: d))
        #expect(m.lookup(path: "/a", size: 11, mtime: t, day: d) == nil)
    }

    /// A rewrite that preserves length changes mtime. Size alone would miss it.
    @Test("mtime change invalidates even at identical size")
    func mtime_change_invalidates() {
        let m = ScanMemo(); let t = Date(timeIntervalSince1970: 1_000); let d = Date(timeIntervalSince1970: 0)
        m.store(path: "/a", entry: entry(size: 10, mtime: t, day: d))
        #expect(m.lookup(path: "/a", size: 10, mtime: t.addingTimeInterval(1), day: d) == nil)
    }

    /// Crossing midnight must not replay yesterday's "today" bucket into
    /// today's — the entry is only valid for the day boundary it was computed
    /// against.
    @Test("day rollover invalidates")
    func day_rollover_invalidates() {
        let m = ScanMemo(); let t = Date(timeIntervalSince1970: 1_000); let d = Date(timeIntervalSince1970: 0)
        m.store(path: "/a", entry: entry(size: 10, mtime: t, day: d))
        #expect(m.lookup(path: "/a", size: 10, mtime: t, day: d.addingTimeInterval(86_400)) == nil)
    }

    @Test("retain drops files that left the window")
    func retain_evicts() {
        let m = ScanMemo(); let t = Date(timeIntervalSince1970: 1_000); let d = Date(timeIntervalSince1970: 0)
        m.store(path: "/a", entry: entry(size: 1, mtime: t, day: d))
        m.store(path: "/b", entry: entry(size: 1, mtime: t, day: d))
        m.retain(paths: ["/a"])
        #expect(m.count == 1)
        #expect(m.lookup(path: "/b", size: 1, mtime: t, day: d) == nil)
    }
}

/// LEAK-MAE-001. The memo keeps one `KeyedUsage` per Claude response in the
/// 7-day window: 35k records on a heavy machine (1.1 GB of transcripts),
/// measured at ~15 MB resident with the full 15-field `ModelUsage` inline.
/// Claude records only ever fill five counts plus a fast flag, so that shape is
/// stored compactly; anything else keeps its exact value out of line.
@Suite("ScanMemo.KeyedUsage — compact storage")
struct KeyedUsageCompactTests {
    @Test("a Claude-shaped record is stored in at most 80 bytes inline")
    func stride_is_compact() {
        #expect(MemoryLayout<ScanMemo.KeyedUsage>.stride <= 80)
    }

    @Test("a standard record round-trips exactly")
    func standard_round_trips() {
        let usage = ModelUsage(inputTokens: 1, outputTokens: 2, cacheReadTokens: 3,
                               cacheCreateTokens: 4, cacheCreate1hTokens: 5)
        let record = ScanMemo.KeyedUsage(model: "m", usage: usage, inToday: true, inWeek: false)
        #expect(record.usage == usage)
        #expect(record.model == "m")
        #expect(record.inToday)
        #expect(!record.inWeek)
    }

    @Test("a fast-mode record round-trips exactly")
    func fast_round_trips() {
        let usage = ModelUsage(inputTokens: 1, outputTokens: 2, cacheReadTokens: 3,
                               cacheCreateTokens: 4, cacheCreate1hTokens: 5,
                               fastInputTokens: 1, fastOutputTokens: 2, fastCacheReadTokens: 3,
                               fastCacheCreateTokens: 4, fastCacheCreate1hTokens: 5)
        let record = ScanMemo.KeyedUsage(model: "m", usage: usage, inToday: true, inWeek: true)
        #expect(record.usage == usage)
    }

    /// Not a shape the Claude scanner produces today, but the type must never
    /// silently drop a field someone adds a producer for.
    @Test("a record outside the compact shape keeps every field")
    func other_shapes_round_trip() {
        let usage = ModelUsage(inputTokens: 10, outputTokens: 20,
                               longContextInputTokens: 10, fastOutputTokens: 7)
        let record = ScanMemo.KeyedUsage(model: "m", usage: usage, inToday: false, inWeek: true)
        #expect(record.usage == usage)
        #expect(record == ScanMemo.KeyedUsage(model: "m", usage: usage, inToday: false, inWeek: true))
        #expect(record != ScanMemo.KeyedUsage(model: "m", usage: ModelUsage(inputTokens: 10),
                                              inToday: false, inWeek: true))
    }

    @Test("dayOffset round-trips in KeyedUsage")
    func day_offset_round_trips() {
        let usage = ModelUsage(inputTokens: 10, outputTokens: 20)
        let record = ScanMemo.KeyedUsage(model: "m", usage: usage, inToday: false, inWeek: true, dayOffset: 3)
        #expect(record.dayOffset == 3)
        #expect(!record.inToday)
        #expect(record.inWeek)
    }
}

@Suite("ClaudeSessionScanner memoization is observable", .serialized)
struct ClaudeScannerMemoTests {
    /// The end-to-end property that matters: a second scan of unchanged files
    /// returns the same money, and an appended file is picked up. If the memo
    /// ever replayed a stale entry, the second assertion fails.
    @Test("repeat scan is stable; appending is picked up")
    func repeat_and_append() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-taskbar-memo-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ input: Int) -> String {
            """
            {"timestamp":"\(iso.string(from: now))","message":{"role":"assistant","model":"claude-opus-5","usage":{"input_tokens":\(input),"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

            """
        }
        let file = proj.appendingPathComponent("a.jsonl")
        try Data(line(1_000_000).utf8).write(to: file)

        let first = ClaudeSessionScanner.estimate(now: now, projectsDir: root)
        let second = ClaudeSessionScanner.estimate(now: now, projectsDir: root)
        #expect(first.usdToday == second.usdToday, "unchanged file must not change the total")
        #expect(abs(first.usdToday - 5.0) < 0.000_001, "1M input on Opus 5 = $5")

        // Append. Size changes, so the memo must invalidate.
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data(line(1_000_000).utf8))
        try handle.close()

        let third = ClaudeSessionScanner.estimate(now: now, projectsDir: root)
        #expect(abs(third.usdToday - 10.0) < 0.000_001, "append must be picked up, got \(third.usdToday)")
    }
}
