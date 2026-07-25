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
    /// What one file contributed, in the window it was scanned for.
    public struct Entry: Sendable {
        public let size: Int
        public let mtime: Date
        /// Totals bucketed by the day boundary they were computed against, so
        /// an entry computed yesterday is not replayed into today's bucket.
        public let computedForDay: Date
        public let today: [String: ModelUsage]
        public let week: [String: ModelUsage]

        public init(size: Int, mtime: Date, computedForDay: Date,
                    today: [String: ModelUsage], week: [String: ModelUsage]) {
            self.size = size
            self.mtime = mtime
            self.computedForDay = computedForDay
            self.today = today
            self.week = week
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
