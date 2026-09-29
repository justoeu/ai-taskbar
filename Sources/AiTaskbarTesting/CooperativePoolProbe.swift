import Foundation

/// Tells a test whether the calling code runs on one of Swift Concurrency's
/// cooperative-pool threads. Those threads run on dispatch root queues whose
/// labels end in `.cooperative`, for example
/// `com.apple.root.default-qos.cooperative`. A plain
/// `DispatchQueue.global()` thread carries the same label without that
/// suffix. `Thread.isMainThread` cannot tell the two apart, and
/// `Task.detached` still runs on the pool.
public enum CooperativePoolProbe {
    public static var currentQueueLabel: String {
        String(cString: __dispatch_queue_get_label(nil))
    }

    public static var isOnCooperativePool: Bool {
        currentQueueLabel.hasSuffix(".cooperative")
    }
}
