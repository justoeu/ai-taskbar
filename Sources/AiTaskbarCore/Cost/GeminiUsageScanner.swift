import Foundation
import SQLite3
import os

/// Local per-model usage for Google's own clients, which no Google API
/// exposes: Gemini CLI chat logs (`~/.gemini/tmp/*/chats/session-*.jsonl`)
/// and Antigravity conversation databases
/// (`~/.gemini/antigravity-cli/conversations/*.db`).
///
/// Token semantics differ per source — do not generalize (see AGENTS.md
/// scanner table; both were measured against real records, 2026-10-14):
///
/// - Gemini CLI rows (`type == "gemini"`): `total == input + output +
///   thoughts` and `cached <= input` on every observed row, so cached is a
///   subset of input (subtract it, Codex-style) and thoughts are billed on
///   top of output (add them, opencode-style). The same message `id` is
///   rewritten while streaming; dedupe by id keeping the largest total.
/// - Antigravity protobufs: fields were calibrated against
///   `agy --output-format json --print` ground truth (input 15535,
///   output 26, thinking 21, cache 0). In the usage message
///   (gen_metadata `1.4`, mirrored in steps metadata field 9):
///   2 = input (non-cached part ONLY — a real generation had input 4712
///   with cache_read 123765, impossible if input included cache),
///   3 = output, 5 = cache_read (proto3 omits zero), 9 = thinking,
///   10 = text output, 11 = response id. `field3 == field9 + field10`
///   held on every sampled generation, so thinking is already inside
///   output — never add it. Model is gen_metadata `1.19`; a generation
///   joins to its step timestamp by response id. Unmatched rows on
///   either side (aborted generations) are skipped, never guessed.
public enum GeminiUsageScanner {

    public static func estimate(now: Date = .init(),
                                geminiHome: URL? = nil) -> CostEstimate {
        let root = geminiHome ?? Paths.geminiHome()
        let window = CostWindow(now: now)
        var totalsToday: [String: ModelUsage] = [:]
        var totalsLast7: [String: ModelUsage] = [:]
        var dailyTotals: [[String: ModelUsage]] = Array(repeating: [:], count: 7)
        var drift = 0
        var sources = 0

        func add(model: String, usage: ModelUsage, at date: Date) {
            guard let slot = window.slotIndex(for: date) else { return }
            CostAggregator.add(usage, into: &totalsLast7, model: model)
            CostAggregator.add(usage, into: &dailyTotals[slot], model: model)
            if date >= window.startOfToday {
                CostAggregator.add(usage, into: &totalsToday, model: model)
            }
        }

        sources += scanChats(home: root, window: window, drift: &drift, add: add)
        sources += scanConversations(home: root, window: window, drift: &drift, add: add)

        let table = PricingTable.antigravity
        let (usdToday, byModelToday) = CostAggregator.price(totals: totalsToday, table: table)
        let (usd7d, byModel7d) = CostAggregator.price(totals: totalsLast7, table: table)
        let dailyUsage = window.calendarDays().enumerated().map { slot, day in
            DailyModelUsage(date: day,
                            usageByModel: slot < dailyTotals.count ? dailyTotals[slot] : [:],
                            costByModel: CostAggregator.price(
                                totals: slot < dailyTotals.count ? dailyTotals[slot] : [:],
                                table: table).1)
        }
        let unpricedToday = Set(totalsToday.keys.filter { PricingTable.lookup($0, table: table) == nil })
        let unpriced7d = Set(totalsLast7.keys.filter { PricingTable.lookup($0, table: table) == nil })
        var notes: [String] = []
        if sources == 0 {
            notes.append("No Gemini CLI or Antigravity records found.")
        } else {
            notes.append("Estimated from local Gemini CLI and Antigravity records at Google AI rates (Claude models routed by Antigravity at Anthropic rates); subscription use has no marginal cost.")
        }
        if !unpriced7d.isEmpty {
            notes.append("Unpriced: \(unpriced7d.sorted().joined(separator: ", ")).")
        }
        if drift > 0 {
            notes.append("\(drift) malformed usage records were skipped.")
        }
        return CostEstimate(
            usdToday: usdToday,
            usdLast7Days: usd7d,
            modelBreakdownToday: byModelToday,
            modelBreakdownLast7Days: byModel7d,
            totalsByModel: totalsToday,
            computedAt: now,
            isApproximate: true,
            note: notes.joined(separator: " "),
            unpricedModelsToday: unpricedToday,
            unpricedModelsLast7Days: unpriced7d,
            dailyUsage: dailyUsage
        )
    }

    // MARK: - Gemini CLI chat logs

    private struct ChatLine: Decodable {
        let id: String?
        let type: String?
        let model: String?
        let timestamp: String?
        let tokens: Tokens?
        struct Tokens: Decodable {
            let input: Int?
            let output: Int?
            let cached: Int?
            let thoughts: Int?
            let total: Int?
        }
    }

    private static func scanChats(home: URL, window: CostWindow, drift: inout Int,
                                  add: (String, ModelUsage, Date) -> Void) -> Int {
        let tmp = home.appendingPathComponent("tmp")
        guard let walker = FileManager.default.enumerator(
            at: tmp,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey,
                                         .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        // Dedupe across the whole scan: streaming rewrites repeat the id.
        var best: [String: (model: String, usage: ModelUsage, at: Date, total: Int)] = [:]
        var files = 0
        let decoder = JSONDecoder()
        let tokenMarker = Data("\"tokens\"".utf8)

        for case let url as URL in walker {
            if Task.isCancelled { break }
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("session-"),
                  url.deletingLastPathComponent().lastPathComponent == "chats"
            else { continue }
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey,
                                                          .isSymbolicLinkKey, .fileSizeKey])
            // Regular files only (a symlink could point at a FIFO or
            // /dev/zero), bounded: a session log is a few MB.
            guard attrs?.isRegularFile == true, attrs?.isSymbolicLink != true,
                  (attrs?.fileSize ?? 0) <= maxChatFileBytes else { continue }
            if let mtime = attrs?.contentModificationDate, mtime < window.startOfLast7Days { continue }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                drift += 1
                continue
            }
            files += 1

            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard line.range(of: tokenMarker) != nil else { continue }
                guard let row = try? decoder.decode(ChatLine.self, from: Data(line)) else {
                    drift += 1
                    continue
                }
                guard row.type == "gemini", let tokens = row.tokens,
                      let model = row.model, !model.isEmpty,
                      let tsText = row.timestamp, let at = ISO8601Parsing.parse(tsText)
                else { continue }
                // Saturating throughout: a row with output = Int.max must not
                // trap the app on every scan.
                let input = max(0, tokens.input ?? 0)
                let cached = min(input, max(0, tokens.cached ?? 0))
                let output = max(0, tokens.output ?? 0)
                    .addingReportingOverflow(max(0, tokens.thoughts ?? 0))
                let billedOutput = output.overflow ? Int.max : output.partialValue
                let usage = ModelUsage(
                    inputTokens: input - cached,
                    outputTokens: billedOutput,
                    cacheReadTokens: cached)
                // The dedupe compares the same clamped figures it bills.
                let sum = input.addingReportingOverflow(billedOutput)
                let total = max(0, tokens.total ?? (sum.overflow ? Int.max : sum.partialValue))
                if let id = row.id, !id.isEmpty {
                    if let existing = best[id], existing.total >= total { continue }
                    best[id] = (model, usage, at, total)
                } else {
                    add(model, usage, at)
                }
            }
        }
        for entry in best.values { add(entry.model, entry.usage, entry.at) }
        return files
    }

    // MARK: - Antigravity conversation databases

    private static func scanConversations(home: URL, window: CostWindow, drift: inout Int,
                                          add: (String, ModelUsage, Date) -> Void) -> Int {
        let dir = home.appendingPathComponent("antigravity-cli/conversations")
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey,
                                         .isSymbolicLinkKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])
        else { return 0 }

        var files = 0
        var seen: Set<String> = []
        for url in entries where url.pathExtension == "db" {
            if Task.isCancelled { break }
            // Regular files only: a symlinked .db could point the read-only
            // open at any other database of the user's.
            guard let attrs = try? url.resourceValues(forKeys: keys),
                  attrs.isRegularFile == true, attrs.isSymbolicLink != true else { continue }
            // A live conversation may keep recent rows in the -wal sidecar,
            // whose mtime is the freshest signal the directory listing has.
            let wal = URL(fileURLWithPath: url.path + "-wal")
            let walAttrs = try? wal.resourceValues(forKeys: keys)
            let mtimes = [attrs.contentModificationDate, walAttrs?.contentModificationDate].compactMap { $0 }
            guard let newest = mtimes.max(), newest >= window.startOfLast7Days else { continue }
            seen.insert(url.path)

            // Memo: an unchanged database (same size + mtime of db and wal)
            // replays its rows instead of being re-opened and re-parsed on
            // every refresh. Rows are stored with their dates and re-filtered
            // by the window at add time, so a cached entry only ages out.
            let stamp = ConversationStamp(size: attrs.fileSize ?? 0, mtime: newest,
                                          walSize: walAttrs?.fileSize ?? 0)
            if let cached = conversationMemo.withLock({ $0[url.path] }), cached.stamp == stamp {
                for row in cached.rows { add(row.model, row.usage, row.at) }
                files += 1
                continue
            }
            var rows: [ConversationRow] = []
            var fileDrift = 0
            if scanConversation(dbPath: url.path, window: window, drift: &fileDrift,
                                add: { rows.append(ConversationRow(model: $0, usage: $1, at: $2)) }) {
                files += 1
                if fileDrift == 0, !Task.isCancelled {
                    let entry = ConversationMemoEntry(stamp: stamp, rows: rows)
                    let path = url.path
                    conversationMemo.withLock { $0[path] = entry }
                }
            }
            drift += fileDrift
            for row in rows { add(row.model, row.usage, row.at) }
        }
        let live = seen
        conversationMemo.withLock { memo in
            memo = memo.filter { live.contains($0.key) }
        }
        return files
    }

    private struct ConversationStamp: Equatable, Sendable {
        let size: Int
        let mtime: Date
        let walSize: Int
    }

    private struct ConversationRow: Sendable {
        let model: String
        let usage: ModelUsage
        let at: Date
    }

    private struct ConversationMemoEntry: Sendable {
        let stamp: ConversationStamp
        let rows: [ConversationRow]
    }

    private static let conversationMemo =
        OSAllocatedUnfairLock<[String: ConversationMemoEntry]>(initialState: [:])

    /// Gemini CLI session logs are a few MB; anything far larger is not one.
    static let maxChatFileBytes = 64 << 20
    /// Generation / step blobs measured at most ~1 MB; larger rows are skipped
    /// (counted as drift) instead of being copied into memory several times.
    static let maxBlobBytes = 8 << 20

    private static func scanConversation(dbPath: String, window: CostWindow, drift: inout Int,
                                         add: (String, ModelUsage, Date) -> Void) -> Bool {
        guard let db = openReadOnly(dbPath) else { return false }
        defer { sqlite3_close(db) }

        // Steps first (small metadata): only generations inside the window
        // need their model resolved from the potentially huge gen blobs.
        var pending: [String: (usage: ModelUsage, at: Date)] = [:]
        let stepsOK = queryBlobs(
            db: db,
            sql: "SELECT metadata FROM steps WHERE step_type = 15 AND metadata IS NOT NULL AND length(metadata) <= \(maxBlobBytes) ORDER BY idx"
        ) { blob in
            guard let step = parseStepMetadata(blob) else { drift += 1; return true }
            let at = Date(timeIntervalSince1970: TimeInterval(step.epochSeconds))
            guard window.slotIndex(for: at) != nil else { return true }
            pending[step.responseID] = (step.usage, at)
            return true
        }
        // A statement that stops short (busy, interrupted, unreadable) is
        // drift, not "no usage": partial results must not read as complete.
        if !stepsOK { drift += 1 }
        guard !pending.isEmpty else { return true }

        // Newest first: in-window generations are the latest rows, so the
        // walk stops as soon as every pending step has found its model.
        let gensOK = queryBlobs(
            db: db,
            sql: "SELECT data FROM gen_metadata WHERE data IS NOT NULL AND length(data) <= \(maxBlobBytes) ORDER BY idx DESC"
        ) { blob in
            guard let gen = parseGeneration(blob) else { drift += 1; return true }
            if let hit = pending.removeValue(forKey: gen.responseID) {
                add(gen.model, hit.usage, hit.at)
            }
            return !pending.isEmpty
        }
        if !gensOK { drift += 1 }
        return true
    }

    static func openReadOnly(_ path: String) -> OpaquePointer? {
        // The database belongs to a possibly running application: read-only,
        // never create. `readonly_shm=1` keeps mode=ro from CREATING a
        // missing `-shm` (plain mode=ro opens it O_CREAT — a file written into
        // Antigravity's directory, review finding on #49); with an existing
        // shm it reads a live WAL normally. `immutable=1` is the fallback: no
        // locking at all, so against a live writer it may see a torn page and
        // fail or skip rows (counted as drift) — never write anything.
        //
        // `sqlite3_open_v2` succeeds lazily: a WAL-mode database with no
        // `-shm` sidecar (23 of 93 Antigravity conversations measured on
        // 2026-10-15) opens fine under mode=ro and then fails its FIRST
        // statement with SQLITE_CANTOPEN, because a read-only connection may
        // not create the shm. Each candidate is therefore proven with a real
        // read before it is returned; checking only the open made every such
        // database read as empty, silently.
        // The path is percent-encoded: a `?`, `#` or `%XX` in a file name
        // would otherwise rewrite the URI's parameters. No
        // SQLITE_OPEN_NOFOLLOW: it rejects a symlink ANYWHERE in the path
        // (`/var` → `/private/var`, a symlinked home), which would silence
        // the scanner again; the caller already skips a symlinked `.db`.
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: uriPathAllowed) else {
            return nil
        }
        for uri in ["file:\(encoded)?mode=ro&readonly_shm=1", "file:\(encoded)?mode=ro&immutable=1"] {
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
            if sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db, canRead(db) {
                sqlite3_progress_handler(db, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
                return db
            }
            sqlite3_close(db)
        }
        return nil
    }

    private static let uriPathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "?#%")
        return set
    }()

    private static func canRead(_ db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Steps one blob column. `body` returns false to stop early. Returns
    /// whether the statement finished cleanly (SQLITE_DONE or an early stop);
    /// a prepare failure or a step error (busy, interrupt, cantopen) is false.
    @discardableResult
    private static func queryBlobs(db: OpaquePointer, sql: String, _ body: (Data) -> Bool) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_ROW else { return rc == SQLITE_DONE }
            guard let raw = sqlite3_column_blob(stmt, 0) else { continue }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            guard count > 0 else { continue }
            if !body(Data(bytes: raw, count: count)) { return true }
        }
    }

    // MARK: - Protobuf field extraction (calibrated layouts only)

    /// Minimal wire-format cursor: yields varint values and byte ranges,
    /// skipping everything else by length. Malformed input ends iteration.
    private struct ProtoFields {
        let bytes: [UInt8]
        var index = 0

        init(_ data: Data) { bytes = [UInt8](data) }
        init(bytes: [UInt8], range: Range<Int>) { self.bytes = Array(bytes[range]) }

        mutating func next() -> (field: Int, varint: UInt64?, bytes: Range<Int>?)? {
            guard let tag = readVarint() else { return nil }
            let field = Int(tag >> 3)
            switch tag & 0x7 {
            case 0:
                guard let value = readVarint() else { return nil }
                return (field, value, nil)
            case 2:
                guard let length = readVarint(), length <= UInt64(bytes.count - index) else { return nil }
                let range = index..<(index + Int(length))
                index += Int(length)
                return (field, nil, range)
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                index += 8
                return (field, nil, nil)
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                index += 4
                return (field, nil, nil)
            default:
                return nil
            }
        }

        private mutating func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 70 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        func string(in range: Range<Int>) -> String? {
            String(bytes: bytes[range], encoding: .utf8)
        }
    }

    private struct ParsedGeneration { let model: String; let responseID: String }
    private struct ParsedStep { let epochSeconds: Int64; let responseID: String; let usage: ModelUsage }

    /// Usage submessage: 2=input, 3=output, 5=cache_read, 11=response id.
    private static func parseUsage(_ parent: inout ProtoFields, range: Range<Int>)
        -> (usage: ModelUsage, responseID: String)? {
        var fields = ProtoFields(bytes: parent.bytes, range: range)
        var input: UInt64 = 0
        var output: UInt64 = 0
        var cache: UInt64 = 0
        var responseID: String?
        while let entry = fields.next() {
            switch entry.field {
            case 2: input = entry.varint ?? input
            case 3: output = entry.varint ?? output
            case 5: cache = entry.varint ?? cache
            case 11:
                if let range = entry.bytes { responseID = fields.string(in: range) }
            default: break
            }
        }
        guard let responseID, !responseID.isEmpty else { return nil }
        return (ModelUsage(inputTokens: Int(clamping: input),
                           outputTokens: Int(clamping: output),
                           cacheReadTokens: Int(clamping: cache)),
                responseID)
    }

    /// gen_metadata blob: field 1 { 4: usage, 19: model }.
    private static func parseGeneration(_ data: Data) -> ParsedGeneration? {
        var top = ProtoFields(data)
        while let entry = top.next() {
            guard entry.field == 1, let range = entry.bytes else { continue }
            var msg = ProtoFields(bytes: top.bytes, range: range)
            var model: String?
            var responseID: String?
            while let inner = msg.next() {
                if inner.field == 19, let r = inner.bytes {
                    model = msg.string(in: r)
                } else if inner.field == 4, let r = inner.bytes {
                    responseID = parseUsage(&msg, range: r)?.responseID
                }
            }
            if let model, !model.isEmpty, let responseID {
                return ParsedGeneration(model: model, responseID: responseID)
            }
            return nil
        }
        return nil
    }

    /// steps metadata: field 1 { 1: epoch seconds }, field 9: usage.
    private static func parseStepMetadata(_ data: Data) -> ParsedStep? {
        var top = ProtoFields(data)
        var epoch: Int64?
        var parsed: (usage: ModelUsage, responseID: String)?
        while let entry = top.next() {
            if entry.field == 1, let range = entry.bytes {
                var ts = ProtoFields(bytes: top.bytes, range: range)
                while let inner = ts.next() {
                    if inner.field == 1, let value = inner.varint {
                        epoch = Int64(clamping: value)
                    }
                }
            } else if entry.field == 9, let range = entry.bytes {
                parsed = parseUsage(&top, range: range)
            }
        }
        guard let epoch, let parsed else { return nil }
        return ParsedStep(epochSeconds: epoch, responseID: parsed.responseID, usage: parsed.usage)
    }
}
