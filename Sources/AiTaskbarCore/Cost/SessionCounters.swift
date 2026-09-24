import Foundation

public enum SessionCounters {
    /// Counts Antigravity conversation database files modified on or after `startDate`.
    public static func antigravityCount(
        since startDate: Date,
        directory: URL? = nil
    ) -> Int {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/conversations")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return 0
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for file in files where file.pathExtension == "db" {
            if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = attrs.contentModificationDate,
               mtime >= startDate {
                count += 1
            }
        }
        return count
    }

    /// Counts Grok session directories modified on or after `startDate`.
    public static func grokCount(
        since startDate: Date,
        directory: URL? = nil
    ) -> Int {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/sessions")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return 0
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for file in files {
            if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = attrs.contentModificationDate,
               mtime >= startDate {
                count += 1
            }
        }
        return count
    }
}
