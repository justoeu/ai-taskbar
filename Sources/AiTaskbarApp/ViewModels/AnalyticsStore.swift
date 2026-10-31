import Foundation
import SwiftUI
import Combine
import AiTaskbarCore
import AiTaskbarProviders

@MainActor
public final class AnalyticsStore: ObservableObject {
    @Published public var timeframe: AnalyticsTimeframe = .daily {
        didSet {
            if oldValue != timeframe {
                recompute()
            }
        }
    }

    @Published public var compareWithPrevious: Bool = false {
        didSet {
            if oldValue != compareWithPrevious {
                recompute()
            }
        }
    }

    @Published public var comparisonOffset: Int = 1 {
        didSet {
            if oldValue != comparisonOffset {
                recompute()
            }
        }
    }

    @Published public private(set) var snapshot: GlobalAnalyticsSnapshot?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastRefreshedAt: Date?

    private static let syncOrderDefaultsKey = "sync_vendor_order"
    private static let analyticsOrderDefaultsKey = "analytics_vendor_order"

    private var cancellables = Set<AnyCancellable>()
    private weak var usageStore: UsageStore?
    private weak var costEstimator: CostEstimator?

    /// When true, AnalyticsView follows the home screen's vendor order.
    @Published public var syncVendorOrder: Bool {
        didSet {
            UserDefaults.standard.set(syncVendorOrder, forKey: Self.syncOrderDefaultsKey)
        }
    }

    /// Independent vendor ordering used when `syncVendorOrder == false`.
    @Published public var analyticsOrder: [VendorId] {
        didSet {
            let rawList = analyticsOrder.map(\.rawValue)
            UserDefaults.standard.set(rawList, forKey: Self.analyticsOrderDefaultsKey)
        }
    }

    /// Transient vendor to scroll to and focus when transitioning from the home screen.
    @Published public var targetVendor: VendorId?

    /// One account's analytics inside a multi-account vendor card.
    public struct AccountSummary: Identifiable {
        public let id: String          // storageKey
        public let name: String
        public let summary: VendorAnalyticsSummary
    }

    /// What `accountSummaries` is built from, per account of a vendor that
    /// has several (two Claude logins).
    public struct AccountInput {
        public let key: ProviderInstanceKey
        public let name: String
        public let estimate: CostEstimate?
        public let snapshot: VendorSnapshot?
    }

    /// Per-account summaries for vendors with several accounts; the card's
    /// "All" position is the vendor summary in `snapshot`.
    @Published public private(set) var accountSummaries: [VendorId: [AccountSummary]] = [:]
    /// The account each multi-account analytics card shows (`storageKey`, or
    /// `allAccountsID`). View state: it resets to "All" on relaunch.
    @Published public var selectedAccount: [VendorId: String] = [:]
    public static let allAccountsID = "all"
    private let accountsProvider: () -> [AccountInput]
    private let accountHistoryProvider: @Sendable (ProviderInstanceKey) -> [UsageHistoryStore.Sample]
    private var accountHistories: [ProviderInstanceKey: [UsageHistoryStore.Sample]] = [:]

    private let estimatesProvider: () -> [VendorId: CostEstimate]
    private let snapshotsProvider: () -> [VendorId: VendorSnapshot]
    private let historyProvider: @Sendable (VendorId) -> [UsageHistoryStore.Sample]
    /// Last histories loaded off the MainActor. `recompute()` aggregates from
    /// these synchronously, so a timeframe switch never waits on disk.
    private var histories: [VendorId: [UsageHistoryStore.Sample]] = [:]
    /// The in-flight off-main history load. Superseded on every trigger, so a
    /// burst of triggers loads each vendor once. Internal so tests can await it.
    private(set) var historyReloadTask: Task<Void, Never>?

    public init(
        estimatesProvider: @escaping () -> [VendorId: CostEstimate] = { [:] },
        snapshotsProvider: @escaping () -> [VendorId: VendorSnapshot] = { [:] },
        historyProvider: @escaping @Sendable (VendorId) -> [UsageHistoryStore.Sample] = { _ in [] },
        accountsProvider: @escaping () -> [AccountInput] = { [] },
        accountHistoryProvider: @escaping @Sendable (ProviderInstanceKey) -> [UsageHistoryStore.Sample] = { _ in [] },
        defaults: UserDefaults = .standard
    ) {
        self.accountsProvider = accountsProvider
        self.accountHistoryProvider = accountHistoryProvider
        self.estimatesProvider = estimatesProvider
        self.snapshotsProvider = snapshotsProvider
        self.historyProvider = historyProvider
        self.syncVendorOrder = defaults.object(forKey: Self.syncOrderDefaultsKey) as? Bool ?? true
        self.analyticsOrder = (defaults.stringArray(forKey: Self.analyticsOrderDefaultsKey) ?? [])
            .compactMap(VendorId.init(rawValue:))
    }

    /// Folds opencode's per-vendor scans into the vendor estimates Analytics
    /// shows. Pure so the default `estimatesProvider` merge is testable.
    nonisolated static func mergingOpencode(
        _ byVendor: [VendorId: CostEstimate],
        opencode: [VendorId: OpencodeScan]
    ) -> [VendorId: CostEstimate] {
        var dict = byVendor
        for (v, scan) in opencode {
            // opencode is a client, not a vendor (see `CostEstimator.opencode`):
            // its tokens are shown, its dollars are never added. OpenAI rides a
            // subscription; xAI/Z.AI/Gemini totals must not be restated. Its
            // models get NO breakdown row either: a $0.00 row would contradict
            // the popover footer, which shows opencode's recorded cost (or its
            // tokens) in a separate section. Only the token totals merge.
            guard let existing = dict[v] else {
                dict[v] = CostEstimate(usdToday: 0, usdLast7Days: 0,
                                       totalsByModel: scan.last7DaysByModel,
                                       dailyUsage: scan.daily)
                continue
            }
            var mergedTotals = existing.totalsByModel
            for (m, u) in scan.last7DaysByModel {
                CostAggregator.add(u, into: &mergedTotals, model: m)
            }
            dict[v] = CostEstimate(
                usdToday: existing.usdToday,
                usdLast7Days: existing.usdLast7Days,
                modelBreakdownToday: existing.modelBreakdownToday,
                modelBreakdownLast7Days: existing.modelBreakdownLast7Days,
                totalsByModel: mergedTotals,
                computedAt: existing.computedAt,
                isApproximate: existing.isApproximate,
                note: existing.note,
                unpricedModelsToday: existing.unpricedModelsToday,
                unpricedModelsLast7Days: existing.unpricedModelsLast7Days,
                // The daily series used to be dropped here, so a vendor with
                // both a scanner and opencode traffic lost its chart.
                dailyUsage: mergingDaily(existing.dailyUsage, opencode: scan.daily)
            )
        }
        return dict
    }

    /// Adds opencode's per-day tokens into a scanner's series, day by day
    /// (same `CostWindow` days). Tokens only: opencode dollars never reach a
    /// vendor's figures, so each day keeps the scanner's `costByModel`.
    nonisolated static func mergingDaily(_ scanner: [DailyModelUsage],
                                         opencode: [DailyModelUsage]) -> [DailyModelUsage] {
        guard !scanner.isEmpty else { return opencode }
        guard !opencode.isEmpty else { return scanner }
        let calendar = Calendar.current
        return scanner.map { day in
            guard let extra = opencode.first(where: { calendar.isDate($0.date, inSameDayAs: day.date) })
            else { return day }
            var usage = day.usageByModel
            for (m, u) in extra.usageByModel {
                CostAggregator.add(u, into: &usage, model: m)
            }
            return DailyModelUsage(date: day.date, usageByModel: usage, costByModel: day.costByModel)
        }
    }

    /// The estimates Analytics shows: the cost scanners' per-vendor totals
    /// with opencode's tokens folded in. Pure and static so the default
    /// `estimatesProvider` is testable without a live `UsageStore` /
    /// `CostEstimator`.
    ///
    /// It takes no snapshots on purpose: **no vendor snapshot contributes
    /// money here.** Every figure lands in a fixed window (`usdToday`,
    /// `usdLast7Days`) and no snapshot carries one: OpenRouter
    /// `/api/v1/activity` covers the last 30 days (no per-item date is
    /// decoded), and xAI `spentUSD` / `prepaidUsedUSD` are
    /// billing-cycle-to-date. Both were once written into `usdLast7Days`; they
    /// stay on the vendor's popover card, which labels their real window.
    nonisolated static func defaultEstimates(
        byVendor: [VendorId: CostEstimate],
        opencode: [VendorId: OpencodeScan]
    ) -> [VendorId: CostEstimate] {
        mergingOpencode(byVendor, opencode: opencode)
    }

    /// Latest good snapshot per vendor, as the popover currently shows it:
    /// for a multi-account vendor, the account its card is showing.
    static func currentSnapshots(_ usageStore: UsageStore?) -> [VendorId: VendorSnapshot] {
        guard let usageStore else { return [:] }
        var dict: [VendorId: VendorSnapshot] = [:]
        for vendor in Set(usageStore.vendors.map(\.vendorId)) {
            if let outcome = usageStore.vendorVM(vendor)?.state.outcome {
                dict[vendor] = outcome.snapshot
            }
        }
        return dict
    }

    /// Every account of every multi-account vendor, with its own cost and
    /// snapshot.
    static func accountInputs(_ usageStore: UsageStore?, _ cost: CostEstimator?) -> [AccountInput] {
        guard let usageStore else { return [] }
        return usageStore.vendorGroups.filter(\.hasAccounts).flatMap { group in
            group.members.map { vm in
                AccountInput(key: vm.instanceKey, name: vm.accountDisplayName,
                             estimate: cost?.byInstance[vm.instanceKey.storageKey],
                             snapshot: vm.state.outcome?.snapshot)
            }
        }
    }

    /// Production per-account history: the instance's own JSONL, 90 days.
    public nonisolated static func diskHistory(instance: ProviderInstanceKey) -> [UsageHistoryStore.Sample] {
        do {
            return try UsageHistoryStore.defaultFor(instance).load(since: Date().addingTimeInterval(-90 * 86_400))
        } catch {
            AppLog.lifecycle.error(
                "analytics history unavailable for \(instance.storageKey, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Production history source: the vendor's on-disk JSONL, last 90 days.
    public nonisolated static func diskHistory(_ vendor: VendorId) -> [UsageHistoryStore.Sample] {
        diskHistory(vendor, makeStore: UsageHistoryStore.defaultFor, onFailure: logHistoryUnavailable)
    }

    /// Analytics has no history for a vendor whose store cannot be created;
    /// that must be visible in the log, as it is for `VendorViewModel`
    /// (BEST-ATE-006 / CQ-MAE-006), not an empty chart with no reason.
    nonisolated static func diskHistory(
        _ vendor: VendorId,
        makeStore: (VendorId) throws -> UsageHistoryStore,
        onFailure: (VendorId, Error) -> Void
    ) -> [UsageHistoryStore.Sample] {
        do {
            return try makeStore(vendor).load(since: Date().addingTimeInterval(-90 * 86_400))
        } catch {
            onFailure(vendor, error)
            return []
        }
    }

    nonisolated static func logHistoryUnavailable(_ vendor: VendorId, _ error: Error) {
        AppLog.lifecycle.error(
            "analytics history unavailable for \(vendor.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    public convenience init(
        usageStore: UsageStore,
        costEstimator: CostEstimator,
        historyProvider: @escaping @Sendable (VendorId) -> [UsageHistoryStore.Sample] = AnalyticsStore.diskHistory
    ) {
        self.init(
            estimatesProvider: { [weak costEstimator] in
                guard let costEstimator else { return [:] }
                return AnalyticsStore.defaultEstimates(
                    byVendor: costEstimator.byVendor,
                    opencode: costEstimator.opencode)
            },
            snapshotsProvider: { [weak usageStore] in
                AnalyticsStore.currentSnapshots(usageStore)
            },
            historyProvider: historyProvider,
            accountsProvider: { [weak usageStore, weak costEstimator] in
                AnalyticsStore.accountInputs(usageStore, costEstimator)
            },
            accountHistoryProvider: { AnalyticsStore.diskHistory(instance: $0) }
        )
        self.usageStore = usageStore
        self.costEstimator = costEstimator

        // Also covers `byInstance`: the estimator assigns it just before
        // `byVendor` in the same main-actor block, so a second sink on it ran
        // every aggregation twice per scan.
        costEstimator.$byVendor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recompute()
            }
            .store(in: &cancellables)

        usageStore.$vendors
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recompute()
            }
            .store(in: &cancellables)
    }

    public func refresh(force: Bool = false) {
        if force {
            guard !isRefreshing else { return }
            isRefreshing = true
            costEstimator?.refresh(force: true)
            usageStore?.refreshAll(forceRefresh: true)
            recompute()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let self else { return }
                self.recompute()
                self.isRefreshing = false
                self.lastRefreshedAt = Date()
            }
        } else {
            recompute()
            if lastRefreshedAt == nil {
                lastRefreshedAt = Date()
            }
        }
    }

    /// Publishes a snapshot from the in-memory inputs right away, then reloads
    /// the 90-day histories off the MainActor and publishes again when they
    /// land. The load used to run synchronously here, on the MainActor, for
    /// every vendor on every trigger (PERF-FLU-001 / LEAK-FAN-003).
    private func recompute() {
        let vendors = publishSnapshot()
        reloadHistories(for: vendors)
    }

    /// Aggregates from the cached histories. Returns the vendors in scope.
    @discardableResult
    private func publishSnapshot() -> Set<VendorId> {
        let estimates = estimatesProvider()
        var snapshots = snapshotsProvider()
        var histories = self.histories
        let accounts = accountsProvider()
        // "All" of a multi-account vendor: cost and tokens are every
        // account's sum, but a quota percentage is not summable. Snapshot
        // AND history come from one account, the most used one, so the
        // position never under-reports nor mixes one account's percentage
        // with another's history.
        for (vendor, inputs) in Dictionary(grouping: accounts, by: \.key.vendor) {
            guard let pick = Self.quotaAccount(inputs) else { continue }
            snapshots[vendor] = pick.snapshot
            histories[vendor] = accountHistories[pick.key] ?? []
        }
        let vendors = Set(estimates.keys).union(snapshots.keys)
        self.snapshot = AnalyticsAggregator.aggregate(
            timeframe: timeframe,
            compareWithPrevious: compareWithPrevious,
            comparisonOffset: comparisonOffset,
            now: Date(),
            histories: histories.filter { vendors.contains($0.key) },
            estimates: estimates,
            snapshots: snapshots
        )
        publishAccountSummaries(accounts)
        return vendors
    }

    /// The account whose quota stands for a multi-account vendor's "All":
    /// the highest current utilization, the first (default) on a tie or
    /// with no snapshot at all.
    static func quotaAccount(_ inputs: [AccountInput]) -> AccountInput? {
        inputs.enumerated().max { a, b in
            let ua = a.element.snapshot?.maxUtilization ?? -1
            let ub = b.element.snapshot?.maxUtilization ?? -1
            return ua != ub ? ua < ub : a.offset > b.offset
        }?.element
    }

    /// Runs the same aggregation once per account, each as if it were the
    /// vendor's only instance, so every chart and figure of the card exists
    /// per account with no second code path.
    private func publishAccountSummaries(_ accounts: [AccountInput]) {
        var out: [VendorId: [AccountSummary]] = [:]
        let now = Date()
        for input in accounts {
            let vendor = input.key.vendor
            let result = AnalyticsAggregator.aggregate(
                timeframe: timeframe,
                compareWithPrevious: compareWithPrevious,
                comparisonOffset: comparisonOffset,
                now: now,
                histories: accountHistories[input.key].map { [vendor: $0] } ?? [:],
                estimates: input.estimate.map { [vendor: $0] } ?? [:],
                snapshots: input.snapshot.map { [vendor: $0] } ?? [:])
            if let summary = result.vendorSummaries.first(where: { $0.vendor == vendor }) {
                out[vendor, default: []].append(AccountSummary(id: input.key.storageKey,
                                                               name: input.name, summary: summary))
            }
        }
        accountSummaries = out
    }

    private func reloadHistories(for vendors: Set<VendorId>) {
        historyReloadTask?.cancel()
        isLoading = true
        let provider = historyProvider
        let accountKeys = accountsProvider().map(\.key)
        let accountProvider = accountHistoryProvider
        historyReloadTask = Task { @MainActor [weak self] in
            // A synchronous burst of triggers cancels this before it runs.
            guard !Task.isCancelled else { return }
            let load = Task.detached(priority: .utility) {
                () -> (vendors: [VendorId: [UsageHistoryStore.Sample]],
                       accounts: [ProviderInstanceKey: [UsageHistoryStore.Sample]])? in
                var loaded: [VendorId: [UsageHistoryStore.Sample]] = [:]
                for vendor in vendors {
                    if Task.isCancelled { return nil }
                    loaded[vendor] = provider(vendor)
                }
                var accounts: [ProviderInstanceKey: [UsageHistoryStore.Sample]] = [:]
                for key in accountKeys {
                    if Task.isCancelled { return nil }
                    // The default account's file IS the vendor's file.
                    accounts[key] = key.account == nil
                        ? loaded[key.vendor] ?? provider(key.vendor)
                        : accountProvider(key)
                }
                return (loaded, accounts)
            }
            let loaded = await withTaskCancellationHandler {
                await load.value
            } onCancel: {
                load.cancel()
            }
            guard let loaded, !Task.isCancelled, let self else { return }
            self.histories = loaded.vendors
            self.accountHistories = loaded.accounts
            self.isLoading = false
            self.publishSnapshot()
        }
    }

    public func displayIndex(of id: VendorId) -> Int {
        analyticsOrder.firstIndex(of: id) ?? Int.max
    }

    public func moveVendorUp(_ id: VendorId, enabled: [VendorId]) {
        move(id, up: true, enabled: enabled)
    }

    public func moveVendorDown(_ id: VendorId, enabled: [VendorId]) {
        move(id, up: false, enabled: enabled)
    }

    /// A no-op press (either end) writes nothing to UserDefaults.
    private func move(_ id: VendorId, up: Bool, enabled: [VendorId]) {
        let next = VendorOrder.moved(id, up: up, order: analyticsOrder, visible: enabled)
        if next != analyticsOrder { analyticsOrder = next }
    }
}
