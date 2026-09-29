import Foundation

/// Resumes after every block already enqueued on the main queue has run.
/// Combine's `receive(on: DispatchQueue.main)` delivers with `main.async`,
/// and the main queue is FIFO, so this is a deterministic "queued sink
/// deliveries have landed" signal — unlike a fixed sleep, it cannot lose a
/// race on a loaded CI machine (TEST-MAE-005 / TEST-MAE-009).
func drainMainQueue() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { c.resume() }
    }
}
