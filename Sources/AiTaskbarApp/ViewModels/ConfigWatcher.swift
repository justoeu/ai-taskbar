import Foundation
import AppKit
import Darwin
import CryptoKit
import AiTaskbarCore

/// Watches `config.toml` for changes and exposes a `configChanged` flag the
/// UI can surface as a "restart to apply" banner.
///
/// Most of the app's wiring (providers, scheduler interval, TLS pinning,
/// language, cache TTL) is captured once at launch and cannot be swapped
/// live without rebuilding the whole object graph — so the pragmatic UX is
/// "detect + prompt restart" rather than hot-reload.
///
/// We hash file contents (SHA-256) rather than relying on mtime alone so
/// that "open + save with no edits" (a common TextEdit behavior) doesn't
/// raise a false alarm.
@MainActor
public final class ConfigWatcher: ObservableObject {
    @Published public private(set) var configChanged: Bool = false

    private let path: URL
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var baselineHash: Data?

    public init(path: URL) {
        self.path = path
        self.baselineHash = Self.hash(of: path)
        arm()
    }

    deinit {
        // The class is @MainActor-isolated, so deinit runs on the main actor
        // at runtime. Swift 6.1+ doesn't infer this for non-Sendable property
        // access in `nonisolated deinit` (the default) — `assumeIsolated`
        // asserts the invariant and lets us reach `source` safely. The
        // cancel handler closes the fd.
        MainActor.assumeIsolated {
            source?.cancel()
        }
    }

    /// Dismiss the banner without restarting. The next change to the file
    /// will raise it again.
    public func dismiss() {
        configChanged = false
        baselineHash = Self.hash(of: path)
    }

    /// Relaunch the .app bundle and terminate the current process. Uses the
    /// classic `sh -c "sleep 1; open <bundle>"` detach trick so the new
    /// instance starts only after the current one has fully exited (macOS
    /// suppresses duplicate launches of a running bundle).
    public func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(bundlePath)\""]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    private func arm() {
        // O_EVTONLY = open for event monitoring; does not count against the
        // process's open-file limit the way O_RDONLY would.
        let cfgPath = path.path
        fd = open(cfgPath, O_EVTONLY)
        guard fd >= 0 else {
            AppLog.lifecycle.error("ConfigWatcher could not open \(cfgPath, privacy: .public) (errno \(errno, privacy: .public))")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main)
        src.setEventHandler { [weak self] in
            self?.handleEvent(src.data)
        }
        src.setCancelHandler { [fd] in
            if fd >= 0 { close(fd) }
        }
        src.resume()
        source = src
    }

    private func handleEvent(_ events: DispatchSource.FileSystemEvent) {
        // On delete/rename the file descriptor is now pointing at the
        // unlinked inode (TextEdit, vim, BBEdit all do tempfile + rename).
        // Re-arm against the new path so we keep watching.
        if events.contains(.delete) || events.contains(.rename) {
            source?.cancel()
            source = nil
            fd = -1
            // Small delay lets the editor finish the rename before we
            // re-open; otherwise we sometimes catch the brief window where
            // the path doesn't exist yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.arm()
                self?.checkForChange()
            }
            return
        }
        checkForChange()
    }

    private func checkForChange() {
        guard let now = Self.hash(of: path) else { return }
        if now != baselineHash {
            baselineHash = now
            configChanged = true
        }
    }

    private static func hash(of url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Data(SHA256.hash(data: data))
    }
}
