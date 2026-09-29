import Foundation

/// The slice of `Process` the re-login tracker needs, so tests can use a fake.
protocol ReloginProcessHandle: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

extension Process: ReloginProcessHandle {}

/// Owns the child spawned by the "Re-login" button (`zsh -l -c <login>`).
/// It used to be a local that was never stored, so every retry after an
/// abandoned browser flow left another login CLI (and its OAuth callback
/// listener) running. Now at most one is alive per vendor: a new spawn
/// terminates the previous one first.
@MainActor
final class ReloginProcessTracker {
    typealias Launcher = @MainActor (String) throws -> ReloginProcessHandle

    private let launch: Launcher
    private(set) var current: ReloginProcessHandle?

    init(launch: @escaping Launcher = ReloginProcessTracker.zshLogin) {
        self.launch = launch
    }

    /// Terminates any previous re-login child, then spawns `command`.
    func start(command: String) throws {
        stop()
        current = try launch(command)
    }

    /// Terminates the tracked child if it is still running.
    func stop() {
        if let current, current.isRunning { current.terminate() }
        current = nil
    }

    /// GUI apps inherit a minimal PATH that excludes `/opt/homebrew/bin`, so
    /// the command runs through a login shell that sources the user's profile.
    static func zshLogin(_ command: String) throws -> ReloginProcessHandle {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", command]
        try task.run()
        return task
    }
}
