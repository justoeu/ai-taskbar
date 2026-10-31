import Foundation
import SwiftUI
import Combine
import AiTaskbarCore
import AiTaskbarProviders

/// Coordinator across the per-vendor ViewModels. Holds shared config
/// (thresholds, primary vendor) and a derived `maxUtilization` that
/// drives the menu-bar icon.
///
/// **Why not a `[VendorId: ProviderState]` here:** that dict made every
/// per-vendor update invalidate the whole store, fanning out re-renders to
/// all `VendorSectionView`s. Per-vendor `VendorViewModel`s plus a Combine
/// subscription that recomputes `maxUtilization` keep the menu bar reactive
/// without rebuilding sections that didn't change.
@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var vendors: [VendorViewModel]
    @Published public var primary: VendorId?
    @Published public private(set) var maxUtilization: Double = 0
    /// Wall-clock instant the scheduler last fired a tick (regardless of
    /// whether each vendor's fetch ultimately succeeded). Drives the
    /// header countdown — basing the countdown on the per-vendor
    /// `lastNetworkFetch` (which only advances on truly fresh data) would
    /// freeze it at 0:00 every time a scheduled tick lands inside the
    /// cache TTL window or the network 429s into the stale fallback path.
    @Published public private(set) var lastScheduledTickAt: Date?
    /// True when at least one vendor is mid-fetch. Pre-computed so the
    /// 1-Hz countdown TimelineView reads it as a flat property instead of
    /// re-running a 6-element enum scan every second.
    @Published public private(set) var isAnyVendorLoading: Bool = false
    /// True if any vendor's most recent refresh ended in HTTP 429 — whether
    /// surfaced directly as `.failed(429, _)` OR masked as a stale-fallback
    /// `.ok(outcome)` whose `outcome.lastError?.status == 429`. CachedFetch
    /// converts a 429 into a stale-`.ok` whenever any cached payload exists
    /// (<7-day maxStale), so checking only `.failed` would miss the
    /// steady-state case and let `RefreshScheduler`'s back-off branch sit
    /// idle. Pre-computed in `recomputeAggregates`.
    @Published public private(set) var hasRateLimitedVendor: Bool = false
    /// `vendors` in display order for the popover. Honors a user-saved order
    /// from `VendorOrder` (UserDefaults `vendor_order`); when unset, configured
    /// providers appear before unconfigured, alpha within each bucket.
    /// Recomputed in `recomputeAggregates` / after drag-reorder.
    @Published public private(set) var sortedVendors: [VendorViewModel] = []
    /// One card per vendor, in display order; a multi-account vendor (two
    /// Claude logins) holds several instances behind one card with an
    /// account switcher. `sortedVendors` is these members flattened.
    @Published public private(set) var vendorGroups: [VendorGroup] = []
    /// The account each multi-account card shows, persisted per vendor.
    @Published public private(set) var selectedAccounts: [VendorId: ProviderInstanceKey] = [:]

    public let thresholds: ThresholdsConfig
    /// Configured scheduler cadence in seconds — surfaced here so views can
    /// render a forward countdown ("Próx. em 4:59") without having to depend
    /// on RefreshScheduler directly. Kept as a constant: changes to
    /// `refresh_interval_seconds` in config.toml require a relaunch to take
    /// effect (same as RefreshScheduler itself), so a `let` is honest.
    public let refreshIntervalSeconds: TimeInterval
    private var subscriptions: Set<AnyCancellable> = []
    private var isSyncingExpansion = false
    /// User-preferred card order (empty = automatic configured-first sort).
    private var preferredOrder: [VendorId]

    public static let pinnedDefaultsKey = "pinned_menu_bar_vendors"

    /// UserDefaults key holding the `storageKey` a multi-account card shows.
    public static func selectedAccountKey(for vendor: VendorId) -> String {
        "selected_account_\(vendor.rawValue)"
    }
    private let defaults: UserDefaults

    public struct PinLimitAlertInfo: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let title: String
        public let message: String

        public init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    /// Pinned vendors in explicit user insertion order. A pin belongs to the
    /// CARD, not to an account: a multi-account vendor gets one menu-bar item
    /// that shows whichever account the card is showing (`selectedAccounts`).
    @Published public private(set) var pinnedVendorOrder: [VendorId] = []

    /// Set of vendors pinned to the macOS menu bar for O(1) membership lookup.
    @Published public private(set) var pinnedVendorIds: Set<VendorId> = []

    /// Alert presented when pinning an item exceeds available menu bar space or hard limits.
    @Published public var pinLimitAlert: PinLimitAlertInfo?

    /// Transient instance focused and scrolled to when clicking a pinned menu bar item.
    @Published public var focusedVendor: ProviderInstanceKey?

    /// Whether the popover / main MenuBarExtra window is currently presented.
    /// Not @Published so transitions do not invalidate SwiftUI views.
    public var isPopoverPresented: Bool = false

    /// Focuses a vendor's card at the account it is showing (a pinned item's
    /// click: the item shows that same account).
    public func focusVendor(_ vendor: VendorId) {
        guard let vm = vendorVM(vendor) else { return }
        focusVendor(vm.instanceKey)
    }

    public func focusVendor(_ id: ProviderInstanceKey) {
        focusedVendor = id
        if vendorVM(instance: id) != nil { selectAccount(id) }
        if let vm = vendorVM(instance: id), !vm.isExpanded {
            vm.isExpanded = true
        }
    }

    /// Safely retrieves and clears transient `focusedVendor` so subsequent popover opens
    /// do not reuse a stale focus target.
    public func consumeFocusedVendor() -> ProviderInstanceKey? {
        let v = focusedVendor
        focusedVendor = nil
        return v
    }

    /// Menu-bar space check consulted before pinning, given the current pin
    /// count. Injected so the denied branch is testable without a live screen;
    /// production uses `PinnedStatusItemManager.shared`.
    public typealias PinSpaceCheck = @MainActor (Int) -> PinnedStatusItemManager.SpaceCheckResult
    private let pinSpaceCheck: PinSpaceCheck

    public init(vendors: [VendorViewModel],
                primary: VendorId?,
                thresholds: ThresholdsConfig = .init(),
                refreshIntervalSeconds: TimeInterval = 300,
                preferredOrder: [VendorId] = VendorOrder.load(),
                defaults: UserDefaults = .standard,
                pinSpaceCheck: @escaping PinSpaceCheck = { count in
                    PinnedStatusItemManager.shared.canAddPinnedStatusItem(currentPinnedCount: count)
                }) {
        self.vendors = vendors
        self.defaults = defaults
        self.pinSpaceCheck = pinSpaceCheck
        self.primary = primary
        self.thresholds = thresholds
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.preferredOrder = preferredOrder
        let savedPinned = Self.pinnedVendors(fromStored: defaults.stringArray(forKey: Self.pinnedDefaultsKey) ?? [])
        self.pinnedVendorOrder = savedPinned
        self.pinnedVendorIds = Set(savedPinned)
        var selected: [VendorId: ProviderInstanceKey] = [:]
        for vendor in Set(vendors.map(\.vendorId)) {
            if let raw = defaults.string(forKey: Self.selectedAccountKey(for: vendor)),
               let key = ProviderInstanceKey(storageKey: raw),
               vendors.contains(where: { $0.instanceKey == key }) {
                selected[vendor] = key
            }
        }
        self.selectedAccounts = selected
        wireUpAggregates()
    }

    /// Merge every vendor's `$state` publisher into one stream, throttle
    /// the result to coalesce bursts (each `VendorViewModel.refresh()`
    /// fires `.loading` → `.ok/.failed` synchronously in quick succession),
    /// then recompute the cross-vendor aggregates exactly once per burst.
    ///
    /// Why we no longer subscribe to `$lastNetworkFetch`: it used to feed
    /// `lastRefreshedAt`, but no view consumes that anymore (the header
    /// countdown anchors on `lastScheduledTickAt`). Dropping the
    /// subscription halves the publisher fan-out per refresh cycle.
    private func wireUpAggregates() {
        subscriptions.removeAll()
        // Merge both `$state` and `$isExpanded` (erased to `Void`) so the
        // menu-bar `maxUtilization` recomputes when the user opens/closes a
        // card, not just when a vendor's fetch resolves.
        let stateStreams = vendors.map {
            $0.$state.map { _ in () }.eraseToAnyPublisher()
        }
        let expandStreams = vendors.map {
            $0.$isExpanded.map { _ in () }.eraseToAnyPublisher()
        }
        Publishers.MergeMany(stateStreams + expandStreams)
            .throttle(for: .milliseconds(50),
                      scheduler: RunLoop.main,
                      latest: true)
            .sink { [weak self] _ in self?.recomputeAggregates() }
            .store(in: &subscriptions)
        // One card per vendor: folding it folds every account behind it, so
        // a hidden account never keeps feeding the menu-bar percentage.
        // `@Published` emits in willSet, before the new value is stored, so a
        // sibling's own sink would see this one still holding the old value
        // and propagate back forever (it overflowed the stack). One sync at a
        // time; the nested emissions it causes are ignored.
        for vm in vendors {
            let siblings = vendors.filter { $0.vendorId == vm.vendorId && $0 !== vm }
            guard !siblings.isEmpty else { continue }
            vm.$isExpanded.dropFirst()
                .sink { [weak self] expanded in
                    guard let self, !self.isSyncingExpansion else { return }
                    self.isSyncingExpansion = true
                    defer { self.isSyncingExpansion = false }
                    for sibling in siblings where sibling.isExpanded != expanded {
                        sibling.isExpanded = expanded
                    }
                }
                .store(in: &subscriptions)
        }
        // Seed the cards so the first render uses the right order (before
        // any state stream fires). Seeding `sortedVendors` alone left
        // `vendorGroups` empty: `applySortedOrder` then saw "same order" and
        // never assigned the groups, so the popover drew no card at all.
        let groups = Self.groups(vendors, preferred: preferredOrder)
        vendorGroups = groups
        sortedVendors = groups.flatMap(\.members)
        recomputeAggregates()
    }

    private func recomputeAggregates() {
        let result = AggregatesComputation.compute(
            entries: vendors.map {
                AggregatesComputation.Entry(state: $0.state,
                                            isExpanded: $0.isExpanded)
            })
        if result.maxUtilization != maxUtilization { maxUtilization = result.maxUtilization }
        if result.isAnyVendorLoading != isAnyVendorLoading { isAnyVendorLoading = result.isAnyVendorLoading }
        if result.hasRateLimitedVendor != hasRateLimitedVendor { hasRateLimitedVendor = result.hasRateLimitedVendor }

        applySortedOrder()
    }

    /// Recompute `vendorGroups` / `sortedVendors` from `preferredOrder` and
    /// the current vendor set. Order is per VENDOR (one card each); members
    /// keep the order the providers were built in (default account first).
    private func applySortedOrder() {
        let groups = Self.groups(vendors, preferred: preferredOrder)
        let newlySorted = groups.flatMap(\.members)
        let sameOrder = newlySorted.count == sortedVendors.count
            && zip(newlySorted, sortedVendors).allSatisfy { $0.id == $1.id }
        if !sameOrder {
            vendorGroups = groups
            sortedVendors = newlySorted
            persistPinned()
        }
    }

    /// Pure grouping, exposed for tests.
    static func groups(_ vendors: [VendorViewModel], preferred: [VendorId]) -> [VendorGroup] {
        var membersByVendor: [VendorId: [VendorViewModel]] = [:]
        var firstSeen: [VendorId] = []
        for vm in vendors {
            if membersByVendor[vm.vendorId] == nil { firstSeen.append(vm.vendorId) }
            membersByVendor[vm.vendorId, default: []].append(vm)
        }
        // A card sinks as unconfigured only when every account behind it is.
        let ids = VendorOrder.ordered(
            entries: firstSeen.map { vendor in
                (vendor, membersByVendor[vendor]?.allSatisfy(\.isDisabled) ?? true)
            },
            preferred: preferred
        )
        return ids.compactMap { vendor in
            membersByVendor[vendor].map { VendorGroup(vendor: vendor, members: $0) }
        }
    }

    // MARK: - Public surface used by views

    public var providerIds: [VendorId] { vendorGroups.map(\.vendor) }
    public var providers: [any UsageProvider] { vendors.map(\.provider) }

    /// The card's instance for a vendor: the selected account when it has
    /// several, its only instance otherwise.
    public func vendorVM(_ id: VendorId) -> VendorViewModel? {
        if let key = selectedAccounts[id], let vm = vendorVM(instance: key) { return vm }
        return vendors.first(where: { $0.vendorId == id })
    }

    public func vendorVM(instance key: ProviderInstanceKey) -> VendorViewModel? {
        vendors.first(where: { $0.instanceKey == key })
    }

    /// The instance a group's card shows.
    public func selectedMember(of group: VendorGroup) -> VendorViewModel {
        if let key = selectedAccounts[group.vendor],
           let vm = group.members.first(where: { $0.instanceKey == key }) {
            return vm
        }
        return group.members[0]
    }

    /// Shows `key`'s account in its vendor's card and remembers the choice.
    public func selectAccount(_ key: ProviderInstanceKey) {
        guard vendorVM(instance: key) != nil, selectedAccounts[key.vendor] != key else { return }
        selectedAccounts[key.vendor] = key
        defaults.set(key.storageKey, forKey: Self.selectedAccountKey(for: key.vendor))
    }

    /// Steps a multi-account card to the next (`+1`) or previous (`-1`)
    /// account, wrapping around.
    public func cycleAccount(_ vendor: VendorId, by step: Int) {
        guard let group = vendorGroups.first(where: { $0.vendor == vendor }), group.members.count > 1,
              let index = group.members.firstIndex(where: { $0 === selectedMember(of: group) }) else { return }
        let count = group.members.count
        selectAccount(group.members[((index + step) % count + count) % count].instanceKey)
    }

    /// Move one step toward the top of the popover list. No-op when already first.
    public func moveVendorUp(_ id: VendorId) {
        let current = vendorGroups.map(\.vendor)
        guard let idx = current.firstIndex(of: id), idx > 0 else { return }
        var next = current
        next.swapAt(idx, idx - 1)
        preferredOrder = next
        VendorOrder.save(preferredOrder)
        applySortedOrder()
    }

    /// Move one step toward the bottom of the popover list. No-op when already last.
    public func moveVendorDown(_ id: VendorId) {
        let current = vendorGroups.map(\.vendor)
        guard let idx = current.firstIndex(of: id), idx < current.count - 1 else { return }
        var next = current
        next.swapAt(idx, idx + 1)
        preferredOrder = next
        VendorOrder.save(preferredOrder)
        applySortedOrder()
    }

    /// Index of `id` in the current display order, or nil if absent.
    public func displayIndex(of id: VendorId) -> Int? {
        vendorGroups.firstIndex(where: { $0.vendor == id })
    }

    public var displayCount: Int { vendorGroups.count }

    public func isPinned(_ id: VendorId) -> Bool {
        pinnedVendorIds.contains(id)
    }

    /// Stored pins read back as vendors, in order, once each. Values written
    /// by per-account builds (`anthropic.<k>`) fold into their vendor.
    static func pinnedVendors(fromStored raw: [String]) -> [VendorId] {
        var seen: Set<VendorId> = []
        return raw.compactMap { ProviderInstanceKey(storageKey: $0)?.vendor }
            .filter { $0.reportsUtilization && seen.insert($0).inserted }
    }

    public func togglePinned(_ id: VendorId, defaults: UserDefaults? = nil) {
        let defaults = defaults ?? self.defaults
        if pinnedVendorIds.contains(id) {
            pinnedVendorIds.remove(id)
            pinnedVendorOrder.removeAll(where: { $0 == id })
            persistPinned(defaults: defaults)
        } else {
            // No utilization to draw (e.g. TypeSafe): a pinned badge would read
            // "0%" forever. The toggle is disabled in the card; this guards
            // every other caller too.
            guard id.reportsUtilization else { return }
            let spaceCheck = pinSpaceCheck(pinnedVendorIds.count)
            guard spaceCheck.allowed else {
                pinLimitAlert = PinLimitAlertInfo(
                    title: L10n.localizedString("pin_limit_reached_title"),
                    message: spaceCheck.reason ?? L10n.localizedString("pin_limit_screen_message")
                )
                return
            }
            pinnedVendorIds.insert(id)
            if !pinnedVendorOrder.contains(id) {
                pinnedVendorOrder.append(id)
            }
            persistPinned(defaults: defaults)
        }
    }

    private func persistPinned(defaults: UserDefaults? = nil) {
        (defaults ?? self.defaults).set(pinnedVendorOrder.map(\.rawValue), forKey: Self.pinnedDefaultsKey)
    }

    public func refreshAll(forceRefresh: Bool = false) {
        for v in vendors { v.refresh(forceRefresh: forceRefresh) }
    }

    /// Longest a fetch may stay in flight before a scheduled tick gives up on
    /// it and restarts the vendor (RACE-MAE-001). Far beyond any legitimate
    /// fetch (HTTP and `agy` budgets are well under a minute) and two default
    /// intervals, so only a truly hung fetch is superseded.
    public static let maxInFlightAge: TimeInterval = 600

    /// Scheduled-tick fan-out: refreshes every vendor except those whose
    /// previous fetch is still in flight. Skipping only the busy vendor keeps
    /// single-flight per vendor without letting one hung fetch (e.g. a child
    /// process that never exits) stall every other vendor (RACE-CRO-003).
    /// A fetch in flight for `maxInFlightAge` or longer no longer counts as
    /// busy: the refresh supersedes (cancels) it, so a hung vendor recovers
    /// without a manual refresh. `now` is the scheduler's clock.
    public func refreshIdleVendors(forceRefresh: Bool = false, now: Date = .now) {
        for v in vendors {
            if v.state.isLoading, let since = v.loadingSince,
               now.timeIntervalSince(since) < Self.maxInFlightAge {
                continue
            }
            v.refresh(forceRefresh: forceRefresh, now: now)
        }
    }

    /// Stamp the scheduler tick that's about to dispatch fetches. The view
    /// reads `lastScheduledTickAt` to anchor the countdown.
    public func markScheduledTick() {
        lastScheduledTickAt = .now
    }

    /// True while RefreshScheduler is sleeping out the extra
    /// `rateLimitBackoff` after a 429 — used by the countdown label to
    /// show "Aguardando rate-limit…" instead of freezing at 0:00.
    @Published public private(set) var isInRateLimitBackoff: Bool = false

    public func enterRateLimitBackoff() {
        if !isInRateLimitBackoff { isInRateLimitBackoff = true }
    }
    public func exitRateLimitBackoff() {
        if isInRateLimitBackoff { isInRateLimitBackoff = false }
    }

    public func refresh(vendor: VendorId, forceRefresh: Bool = true) {
        vendorVM(vendor)?.refresh(forceRefresh: forceRefresh)
    }

    /// Schedules a history compaction off the MainActor. The history stores
    /// are `@unchecked Sendable` with internal `NSLock` serialization, so
    /// `compact()` is safe to invoke from a background task. Use this from
    /// `RefreshScheduler` so launch-time compaction (6 vendors × up to
    /// ~300 KB JSONL) doesn't block the UI for 100–500 ms.
    public func compactAllHistoryDetached() {
        let stores = vendors.compactMap { $0.historyStore }
        guard !stores.isEmpty else { return }
        Task.detached(priority: .utility) {
            for store in stores { store.compact() }
        }
    }
}

/// One card in the popover: a vendor and the instance(s) behind it.
public struct VendorGroup: Identifiable {
    public let vendor: VendorId
    /// Never empty; the default account first.
    public let members: [VendorViewModel]
    public var id: VendorId { vendor }
    public var hasAccounts: Bool { members.count > 1 }
}

/// Pure aggregation logic extracted from `UsageStore.recomputeAggregates()`.
/// Computes the cross-vendor `maxUtilization` / `isAnyVendorLoading` /
/// `hasRateLimitedVendor` flags from a list of per-vendor states. Exposed so
/// the subtle `hasRateLimitedVendor` invariant — which must fire on BOTH
/// `.failed(429, _)` AND stale-`.ok(outcome)` whose `outcome.lastError?.status
/// == 429` (CachedFetch converts a 429 into a stale `.ok` whenever a cached
/// payload exists) — can be unit-tested without standing up the full store.
@MainActor
public enum AggregatesComputation {
    public struct Result: Equatable {
        public let maxUtilization: Double
        public let isAnyVendorLoading: Bool
        public let hasRateLimitedVendor: Bool

        public init(maxUtilization: Double,
                    isAnyVendorLoading: Bool,
                    hasRateLimitedVendor: Bool) {
            self.maxUtilization = maxUtilization
            self.isAnyVendorLoading = isAnyVendorLoading
            self.hasRateLimitedVendor = hasRateLimitedVendor
        }
    }

    /// One vendor's contribution to the aggregate: its refresh `state` plus
    /// whether its popover card is currently expanded (open). `isExpanded`
    /// gates ONLY `maxUtilization` — a collapsed (closed) card is disregarded
    /// by the menu-bar percentage. The `isAnyVendorLoading` /
    /// `hasRateLimitedVendor` flags still consider every vendor regardless of
    /// expand state (they drive the header countdown and the scheduler
    /// back-off, which must not go blind just because the user folded a card).
    public struct Entry {
        public let state: VendorViewModel.State
        public let isExpanded: Bool
        public init(state: VendorViewModel.State, isExpanded: Bool) {
            self.state = state
            self.isExpanded = isExpanded
        }
    }

    /// Back-compat overload: treats every vendor as expanded, i.e. the
    /// pre-filter behavior where the bar folded all vendors into the max.
    public static func compute(states: [VendorViewModel.State]) -> Result {
        compute(entries: states.map { Entry(state: $0, isExpanded: true) })
    }

    public static func compute(entries: [Entry]) -> Result {
        var maxUtil = 0.0
        var loading = false
        var rateLimited = false
        // Single pass so the steady-state cost is O(vendors), not 2×.
        for entry in entries {
            let state = entry.state
            // Loading / rate-limit flags fold EVERY vendor — independent of
            // whether its card is open.
            switch state {
            case .idle:
                break
            case .loading:
                loading = true
            case .ok(let outcome):
                if outcome.lastError?.status == 429 { rateLimited = true }
            case .failed(let err, let fallback):
                if err.isRateLimited || fallback?.lastError?.status == 429 {
                    rateLimited = true
                }
            }
            // maxUtilization only folds OPEN cards. `state.outcome` yields the
            // fresh outcome for `.ok`, the stale fallback for `.failed`, and
            // the previous snapshot for `.loading(previous:)` — so a just-
            // started refresh does not drop the menu bar to 0%.
            guard entry.isExpanded else { continue }
            if let m = state.outcome?.snapshot.maxUtilization, m > maxUtil {
                maxUtil = m
            }
        }
        return Result(maxUtilization: maxUtil,
                      isAnyVendorLoading: loading,
                      hasRateLimitedVendor: rateLimited)
    }
}
