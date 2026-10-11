import Foundation

/// Per-file memo for the transcript scanners.
///
/// Both scanners re-read every file inside the 7-day window on every refresh —
/// measured at 191 MB across 839 files, 2.0 s warm and 6.0 s cold, every 60 s.
/// Transcripts are append-only and nearly all of them are byte-identical to
/// the previous pass (838 of 839 in the measured case), so almost all of that
/// work is repeated for no new information.
///
/// This memoizes each file's contribution keyed on its identity **and** its
/// mutation state (size + mtime). A file whose size and mtime both match the
/// previous pass replays its cached totals instead of being re-parsed.
///
/// Why size AND mtime rather than either alone: mtime has 1-second resolution
/// on some filesystems, so an append within the same second as the previous
/// scan would go unnoticed by mtime; and a rewrite that preserves length would
/// go unnoticed by size. A file being appended to gets a new size, a file
/// being rewritten gets a new mtime, and the pair catches both. This is a
/// cache-invalidation heuristic on data we don't control, not a content hash —
/// it is deliberately cheap, and the cost of being wrong is a stale number for
/// one refresh cycle, not a wrong permanent total.
///
/// Deliberately in-memory only: persisting it would mean reasoning about a
/// cache file that outlives an app version whose parsing rules may have
/// changed, to save a cold start that happens once per launch.
public final class ScanMemo: @unchecked Sendable {
    /// One API response identified by a request key (Claude: message.id +
    /// requestId). Kept un-aggregated because the same response can be
    /// written to several files, and dedup has to happen across all of them.
    ///
    /// Stored compactly because the memo holds one per response in the window:
    /// 35k on a heavy machine (1.1 GB of transcripts), ~15 MB resident with the
    /// 15-field `ModelUsage` inline (LEAK-MAE-001). A Claude record fills only
    /// five counts, with the fast subsets either zero or equal to them, so that
    /// shape keeps five `Int`s and a flag (stride 144 -> 72 bytes, ~9 MB on the
    /// same data). Any other shape keeps its exact value in `boxed`, so the
    /// round trip is lossless whatever the producer.
    public struct KeyedUsage: Sendable, Equatable {
        public let model: String
        public let inToday: Bool
        public let inWeek: Bool
        public let dayOffset: Int8
        private let isFast: Bool
        private let input: Int
        private let output: Int
        private let cacheRead: Int
        private let cacheCreate: Int
        private let cacheCreate1h: Int
        private let boxed: Boxed?

        private final class Boxed: Sendable {
            let usage: ModelUsage
            init(_ usage: ModelUsage) { self.usage = usage }
        }

        public init(model: String, usage: ModelUsage, inToday: Bool, inWeek: Bool, dayOffset: Int8 = -1) {
            self.model = model
            self.inToday = inToday
            self.inWeek = inWeek
            self.dayOffset = dayOffset
            let isFast = usage.fastInputTokens != 0 || usage.fastOutputTokens != 0
                || usage.fastCacheReadTokens != 0 || usage.fastCacheCreateTokens != 0
                || usage.fastCacheCreate1hTokens != 0
            self.isFast = isFast
            self.input = usage.inputTokens
            self.output = usage.outputTokens
            self.cacheRead = usage.cacheReadTokens
            self.cacheCreate = usage.cacheCreateTokens
            self.cacheCreate1h = usage.cacheCreate1hTokens
            let compact = Self.expand(input: input, output: output, cacheRead: cacheRead,
                                      cacheCreate: cacheCreate, cacheCreate1h: cacheCreate1h,
                                      isFast: isFast)
            self.boxed = compact == usage ? nil : Boxed(usage)
        }

        public var usage: ModelUsage {
            if let boxed { return boxed.usage }
            return Self.expand(input: input, output: output, cacheRead: cacheRead,
                               cacheCreate: cacheCreate, cacheCreate1h: cacheCreate1h,
                               isFast: isFast)
        }

        public static func == (lhs: KeyedUsage, rhs: KeyedUsage) -> Bool {
            lhs.model == rhs.model && lhs.inToday == rhs.inToday
                && lhs.inWeek == rhs.inWeek && lhs.dayOffset == rhs.dayOffset
                && lhs.usage == rhs.usage
        }

        private static func expand(input: Int, output: Int, cacheRead: Int,
                                   cacheCreate: Int, cacheCreate1h: Int,
                                   isFast: Bool) -> ModelUsage {
            ModelUsage(inputTokens: input, outputTokens: output,
                       cacheReadTokens: cacheRead, cacheCreateTokens: cacheCreate,
                       cacheCreate1hTokens: cacheCreate1h,
                       fastInputTokens: isFast ? input : 0,
                       fastOutputTokens: isFast ? output : 0,
                       fastCacheReadTokens: isFast ? cacheRead : 0,
                       fastCacheCreateTokens: isFast ? cacheCreate : 0,
                       fastCacheCreate1hTokens: isFast ? cacheCreate1h : 0)
        }
    }

    /// What one file contributed, in the window it was scanned for.
    public struct Entry: Sendable {
        public let size: Int
        public let mtime: Date
        /// Totals bucketed by the day boundary they were computed against, so
        /// an entry computed yesterday is not replayed into today's bucket.
        public let computedForDay: Date
        public let today: [String: ModelUsage]
        public let week: [String: ModelUsage]
        public let daily: [[String: ModelUsage]]
        /// Keyed records, NOT folded into `today`/`week`, so the caller can
        /// dedup them against other files before aggregating.
        public let keyed: [String: KeyedUsage]

        public init(size: Int, mtime: Date, computedForDay: Date,
                    today: [String: ModelUsage], week: [String: ModelUsage],
                    daily: [[String: ModelUsage]] = [],
                    keyed: [String: KeyedUsage] = [:]) {
            self.size = size
            self.mtime = mtime
            self.computedForDay = computedForDay
            self.today = today
            self.week = week
            self.daily = daily
            self.keyed = keyed
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    /// Returns the memoized contribution when the file is unchanged AND was
    /// computed for the same day boundary. Any mismatch returns nil, which
    /// makes the caller re-parse — the safe direction.
    public func lookup(path: String, size: Int, mtime: Date, day: Date) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[path],
              e.size == size,
              e.mtime == mtime,
              e.computedForDay == day
        else { return nil }
        return e
    }

    public func store(path: String, entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        entries[path] = entry
    }

    /// Drops entries for files no longer in the window so the memo can't grow
    /// without bound across a long-running session.
    public func retain(paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { paths.contains($0.key) }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
