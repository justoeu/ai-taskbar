import Foundation
import SwiftUI
import Combine
import Darwin
import AiTaskbarCore
import AiTaskbarProviders

/// One ObservableObject per vendor section. Splitting state per-vendor means
/// a Claude refresh only re-renders the Claude section — not the OpenAI/Z.AI/
/// OpenRouter/Kimi sections. (Previously a single `UsageStore.@Published states`
/// dict fanned out invalidations to every `VendorSectionView`.)
@MainActor
public final class VendorViewModel: ObservableObject, Identifiable {
    public enum State: Equatable {
        case idle
        case loading
        case ok(FetchOutcome)
        case failed(error: AppError, fallback: FetchOutcome?)

        public var outcome: FetchOutcome? {
            switch self {
            case .ok(let o): return o
            case .failed(_, let o): return o
            default: return nil
            }
        }
    }

    // `id` is nonisolated because the underlying `vendorId` is a `let` and
    // `Identifiable` requirement is itself nonisolated. Silences a Swift 6
    // strict-concurrency conformance warning.
    public nonisolated var id: VendorId { vendorId }
    public nonisolated let vendorId: VendorId
    public let provider: any UsageProvider

    @Published public private(set) var state: State = .idle
    @Published public private(set) var history: [UsageHistoryStore.Sample] = []
    @Published public private(set) var lastNetworkFetch: Date?

    /// Whether this vendor's card is expanded (open) in the popover. This is
    /// the single source of truth for BOTH the section chevron UI and the
    /// menu-bar `maxUtilization` filter: a collapsed (closed) card is excluded
    /// from the percentage shown in the bar (see `AggregatesComputation`). It
    /// used to live as a `@State` inside `VendorSectionView`, but the bar
    /// needs to read it, so it's hoisted here. Seeded from UserDefaults on
    /// init; the `didSet` persists every change back (the initial assignment
    /// in `init` does not fire `didSet`, so no redundant write on launch).
    @Published public var isExpanded: Bool {
        didSet {
            guard isExpanded != oldValue else { return }
            UserDefaults.standard.set(isExpanded,
                                      forKey: Self.expansionKey(for: vendorId))
        }
    }

    /// UserDefaults key backing `isExpanded`. Unchanged from the key the old
    /// `VendorSectionView` used, so existing users keep their saved layout.
    public static func expansionKey(for vendor: VendorId) -> String {
        "expanded_\(vendor.rawValue)"
    }

    /// True when the vendor's last fetch was rejected with a 401 — either a
    /// hard `.failed` on a cold cache, or a stale-but-served snapshot whose
    /// `lastError` carries the 401. Drives the per-vendor "Re-login" button
    /// (see `VendorSectionView`). Stays false for non-OAuth vendors that lack
    /// a `reloginCommand`.
    public var needsReauth: Bool {
        switch state {
        case .failed(let err, _):
            return err.isUnauthorized
        case .ok(let outcome) where outcome.isStale:
            return outcome.lastError?.status == 401
        default:
            return false
        }
    }

    /// Schedules a couple of delayed re-checks after the user kicks off a CLI
    /// re-login in a separate Terminal window. The OAuth browser flow takes a
    /// variable amount of time, so we poke the endpoint again after a delay;
    /// once the token is renewed the 401 clears, `needsReauth` flips false,
    /// and the loop bails out early. Keeps the monitor from showing a stale
    /// "token expired" banner until the next 300 s scheduled tick.
    public func scheduleReauthRetry() {
        Task { @MainActor [weak self] in
            for delaySec in [30, 75] {
                try? await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
                guard let self else { return }
                guard self.needsReauth else { return }  // recovered → stop poking
                self.refresh(forceRefresh: true)
            }
        }
    }

    public let historyStore: UsageHistoryStore?
    private weak var notifications: NotificationService?
    /// Bumped on every refresh — used to track in-flight task ownership
    /// without racing on Task identity.
    private var epoch: Int = 0

    /// Filesystem watcher on the provider's `credentialFileURL` (currently
    /// only OpenAI/Codex `auth.json`). Fires when an external `codex login`
    /// renews the token, so the vendor refreshes immediately instead of
    /// waiting up to 300 s for the next scheduled tick. nil for providers
    /// without a file-backed credential. No `deinit`: the source lives for
    /// the app lifetime, mirroring `ConfigWatcher` (a resumed DispatchSource
    /// can't be safely cancelled from a nonisolated deinit under Swift 6).
    private var credWatcher: DispatchSourceFileSystemObject?
    private var credDebounce: Task<Void, Never>?

    public init(provider: any UsageProvider,
                notifications: NotificationService? = nil) {
        self.vendorId = provider.vendorId
        self.provider = provider
        self.notifications = notifications
        self.isExpanded = (UserDefaults.standard
            .object(forKey: Self.expansionKey(for: provider.vendorId)) as? Bool) ?? true
        self.historyStore = try? UsageHistoryStore.defaultFor(provider.vendorId)
        if let store = historyStore {
            self.history = store.load(since: Date.now.addingTimeInterval(-24 * 3600))
        }
        if let credPath = provider.credentialFileURL {
            armCredentialWatcher(path: credPath)
        }
    }

    /// Arms a DispatchSource on the credential file. Coalesces rapid writes
    /// (codex's atomic write = tempfile + rename) into a single delayed
    /// refresh so we don't fan out redundant network calls.
    private func armCredentialWatcher(path: URL) {
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main)
        src.setEventHandler { [weak self] in
            self?.handleCredentialChange(events: src.data, path: path)
        }
        src.setCancelHandler { [fd] in
            if fd >= 0 { close(fd) }
        }
        src.resume()
        credWatcher = src
    }

    private func handleCredentialChange(events: DispatchSource.FileSystemEvent,
                                        path: URL) {
        // Atomic write (tempfile + rename) leaves the fd pointing at the
        // unlinked inode — cancel (fires the cancel handler → closes the old
        // fd), re-arm against the new path, then refresh.
        if events.contains(.delete) || events.contains(.rename) {
            credWatcher?.cancel()
            credWatcher = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.armCredentialWatcher(path: path)
                self?.scheduleCredentialRefresh()
            }
            return
        }
        scheduleCredentialRefresh()
    }

    /// Debounce rapid credential writes into one refresh after 0.5 s.
    private func scheduleCredentialRefresh() {
        credDebounce?.cancel()
        credDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.refresh(forceRefresh: true)
        }
    }

    public func refresh(forceRefresh: Bool) {
        epoch += 1
        let myEpoch = epoch
        state = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.provider.fetchUsage(forceRefresh: forceRefresh)
                if Task.isCancelled { return }
                guard myEpoch == self.epoch else { return }   // newer refresh wins
                self.state = .ok(outcome)
                if (outcome.cacheAge ?? .greatestFiniteMagnitude) <= 1 {
                    self.lastNetworkFetch = .now
                }
                self.notifications?.observe(vendor: self.vendorId, snapshot: outcome.snapshot)
                self.recordHistory(outcome.snapshot.maxUtilization)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                guard myEpoch == self.epoch else { return }
                let appErr = AppError.wrapping(error)
                let fallback = self.state.outcome
                self.state = .failed(error: appErr, fallback: fallback)
            }
        }
    }

    private func recordHistory(_ maxUtilization: Double) {
        guard let store = historyStore else { return }
        store.append(maxUtilization: maxUtilization)
        let sample = UsageHistoryStore.Sample(
            at: Date.now.timeIntervalSince1970,
            max: maxUtilization
        )
        let cutoff = Date.now.addingTimeInterval(-24 * 3600).timeIntervalSince1970
        var current = history
        current.append(sample)
        history = current.filter { $0.at >= cutoff }
    }

    public func compactHistory() {
        historyStore?.compact()
    }
}
