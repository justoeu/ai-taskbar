import Testing
import Foundation
@testable import AiTaskbarApp
import AiTaskbarCore
@testable import AiTaskbarProviders

/// SDD-claude-multi-account §6: several Claude accounts as instances of one
/// vendor, grouped in one card.
private struct AccountProvider: UsageProvider {
    let vendorId: VendorId
    let instanceKey: ProviderInstanceKey
    let accountLabel: String?

    init(_ vendor: VendorId, account: String? = nil, label: String? = nil) {
        vendorId = vendor
        instanceKey = ProviderInstanceKey(vendor: vendor, account: account)
        accountLabel = label
    }

    func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        FetchOutcome(snapshot: .zai(ZAISnapshot(session: UsageWindow(label: "Session", utilizationPercent: 10))))
    }
}

private struct NoHistory: Error {}

@MainActor
@Suite("Claude multi-account — store, pins, focus", .serialized)
final class ClaudeMultiAccountStoreTests {
    private let suiteName = "ClaudeMultiAccountStoreTests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let work = ProviderInstanceKey(vendor: .anthropic, account: "aaaa1111")

    init() { defaults = UserDefaults(suiteName: suiteName)! }
    deinit { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

    private func vm(_ provider: AccountProvider) -> VendorViewModel {
        VendorViewModel(provider: provider, defaults: defaults, historyStoreFactory: { _ in throw NoHistory() })
    }

    private func makeStore() -> (UsageStore, main: VendorViewModel, extra: VendorViewModel) {
        let main = vm(AccountProvider(.anthropic))
        let extra = vm(AccountProvider(.anthropic, account: "aaaa1111", label: "work"))
        let openai = vm(AccountProvider(.openai))
        let store = UsageStore(vendors: [main, extra, openai], primary: nil, preferredOrder: [],
                               defaults: defaults, pinSpaceCheck: { _ in .init(allowed: true, reason: nil) })
        return (store, main, extra)
    }

    @Test("two Claude instances group into one card instead of crashing")
    func grouping() {
        let (store, _, _) = makeStore()
        #expect(store.vendorGroups.map(\.vendor) == [.anthropic, .openai])
        #expect(store.vendorGroups.first?.members.count == 2)
        #expect(store.sortedVendors.count == 3)
        #expect(Set(store.sortedVendors.map(\.id)).count == 3)
        #expect(store.displayCount == 2)
        #expect(store.providerIds == [.anthropic, .openai])
    }

    @Test("the card shows the default account until another is selected, and remembers it")
    func selection() {
        let (store, main, extra) = makeStore()
        let group = store.vendorGroups[0]
        #expect(store.selectedMember(of: group) === main)
        store.selectAccount(work)
        #expect(store.selectedMember(of: group) === extra)
        #expect(store.vendorVM(.anthropic) === extra)
        #expect(defaults.string(forKey: UsageStore.selectedAccountKey(for: .anthropic)) == "anthropic.aaaa1111")
        let reopened = UsageStore(vendors: store.vendors, primary: nil, preferredOrder: [], defaults: defaults)
        #expect(reopened.vendorVM(.anthropic) === extra)
    }

    @Test("stepping through accounts wraps around")
    func cycling() {
        let (store, main, extra) = makeStore()
        store.cycleAccount(.anthropic, by: 1)
        #expect(store.vendorVM(.anthropic) === extra)
        store.cycleAccount(.anthropic, by: 1)
        #expect(store.vendorVM(.anthropic) === main)
        store.cycleAccount(.anthropic, by: -1)
        #expect(store.vendorVM(.anthropic) === extra)
    }

    @Test("a pin belongs to the card: pinning one account pins the vendor")
    func pins() {
        let (store, _, _) = makeStore()
        store.togglePinned(.anthropic)
        expectTrue(store.isPinned(.anthropic))
        #expect(store.pinnedVendorOrder == [.anthropic])
        #expect(defaults.stringArray(forKey: UsageStore.pinnedDefaultsKey) == ["anthropic"])
    }

    @Test("stored per-account pins fold into one pin per vendor, in order")
    func pins_from_per_account_builds() {
        #expect(UsageStore.pinnedVendors(fromStored: ["anthropic.aaaa1111", "openai", "anthropic", "bogus"])
                == [.anthropic, .openai])
        #expect(UsageStore.pinnedVendors(fromStored: ["typesafe"]).isEmpty)
    }

    @Test("the pinned item shows the account the card shows, and follows navigation")
    func pinned_item_follows_selected_account() {
        let (store, _, _) = makeStore()
        store.togglePinned(.anthropic)
        let manager = PinnedStatusItemManager()
        defer { manager.removeAll() }
        manager.configure(store: store)
        manager.mainStatusItemDidAppear()
        manager.syncStatusItems()
        #expect(manager.physicalItems.count == 1)
        let item = manager.statusItem(for: .anthropic)
        expectTrue(item?.button?.toolTip?.hasPrefix("Claude:") ?? false)

        store.cycleAccount(.anthropic, by: 1)
        manager.syncStatusItems()
        #expect(manager.physicalItems.count == 1)
        #expect(manager.statusItem(for: .anthropic) === item)
        expectTrue(item?.button?.toolTip?.hasPrefix("Claude · work:") ?? false)
    }

    @Test("a pin with no instance this launch keeps its entry but draws no item")
    func pin_without_instance() {
        defaults.set(["gemini"], forKey: UsageStore.pinnedDefaultsKey)
        let (store, _, _) = makeStore()
        let manager = PinnedStatusItemManager()
        defer { manager.removeAll() }
        manager.configure(store: store)
        manager.mainStatusItemDidAppear()
        manager.syncStatusItems()
        #expect(manager.physicalItems.isEmpty)
        expectTrue(store.isPinned(.gemini))
    }

    @Test("clicking a pinned vendor focuses the account its card shows")
    func focus_by_vendor() {
        let (store, _, extra) = makeStore()
        store.selectAccount(work)
        store.focusVendor(VendorId.anthropic)
        #expect(store.consumeFocusedVendor() == work)
        expectTrue(extra.isExpanded)
    }

    @Test("focusing a pinned account selects it in its card and opens the card")
    func focus() {
        let (store, _, extra) = makeStore()
        extra.isExpanded = false
        store.focusVendor(work)
        #expect(store.vendorVM(.anthropic) === extra)
        expectTrue(extra.isExpanded)
        #expect(store.consumeFocusedVendor() == work)
    }

    @Test("folding the card folds every account behind it")
    func shared_expansion() {
        let (store, main, extra) = makeStore()
        defer { withExtendedLifetime(store) {} }
        main.isExpanded = false
        expectFalse(extra.isExpanded)
        extra.isExpanded = true
        expectTrue(main.isExpanded)
    }

    @Test("reordering moves the whole card")
    func reorder() {
        let (store, _, _) = makeStore()
        store.moveVendorDown(.anthropic)
        #expect(store.vendorGroups.map(\.vendor) == [.openai, .anthropic])
        #expect(store.sortedVendors.map(\.vendorId) == [.openai, .anthropic, .anthropic])
    }
}

@MainActor
@Suite("Claude multi-account — names and keys")
struct ClaudeMultiAccountNamingTests {
    private let work = ProviderInstanceKey(vendor: .anthropic, account: "aaaa1111")
    private let window = UsageWindow(label: "7d", utilizationPercent: 91)

    @Test("notification identifiers stay legacy for the default and differ per account")
    func notification_identifiers() {
        #expect(NotificationService.identifier(instance: ProviderInstanceKey(vendor: .anthropic),
                                               window: window, threshold: 90) == "ai-taskbar.anthropic.7d.90")
        #expect(NotificationService.identifier(instance: work, window: window, threshold: 90)
                == "ai-taskbar.anthropic.aaaa1111.7d.90")
    }

    @Test("a notification names the account")
    func notification_title() {
        let title = NotificationService.title(vendor: .anthropic, accountLabel: "work", window: window)
        #expect(title.contains("Claude · work"))
        #expect(!NotificationService.title(vendor: .anthropic, window: window).contains("·"))
    }

    @Test("the rotating label adds the account initial")
    func short_label() {
        #expect(MenuBarLabelView.shortLabel(for: .anthropic, accountLabel: nil) == "Cl")
        #expect(MenuBarLabelView.shortLabel(for: .anthropic, accountLabel: "work") == "Cl·w")
    }

    @Test("a pinned badge's tooltip names the account")
    func tooltip() {
        let text = MenuBarTooltipBuilder.buildTooltip(vendorId: .anthropic, accountLabel: "work",
                                                      snapshot: nil, currentPercent: 12)
        #expect(text.hasPrefix("Claude · work:"))
    }

    @Test("a multi-account vendor keeps the one legacy autosave name")
    func autosave_names() {
        #expect(PinnedStatusItemManager.autosaveName(for: .anthropic) == "ai-taskbar.pinned.anthropic")
    }

    @Test("history files: legacy name for the default account, suffixed per extra")
    func history_files() {
        let dir = URL(fileURLWithPath: "/tmp/h")
        #expect(UsageHistoryStore(vendor: .anthropic, baseDir: dir).fileURL.lastPathComponent == "anthropic.jsonl")
        #expect(UsageHistoryStore(instance: work, baseDir: dir).fileURL.lastPathComponent
                == "anthropic.aaaa1111.jsonl")
    }
}

@Suite("Claude multi-account — providers")
@MainActor
struct ClaudeMultiAccountProviderTests {
    private func account(_ label: String?, account: String?, dir: String) -> ClaudeAccount {
        ClaudeAccount(instanceKey: ProviderInstanceKey(vendor: .anthropic, account: account), label: label,
                      configDir: URL(fileURLWithPath: dir),
                      keychainService: account == nil ? "Claude Code-credentials" : "Claude Code-credentials-x")
    }

    private func env(_ accounts: [ClaudeAccount]) -> AppEnvironment {
        AppEnvironment(http: HTTPClient(), configLoader: ConfigLoader(path: URL(fileURLWithPath: "/tmp/none.toml")),
                       config: AppConfig(), claudeAccounts: accounts)
    }

    private func cleanup(_ providers: [any UsageProvider]) {
        for p in providers where p.instanceKey.account != nil {
            if let dir = try? Paths.cacheDir(for: p.instanceKey) { try? FileManager.default.removeItem(at: dir) }
        }
    }

    @Test("nothing discovered builds the single default provider, as before")
    func none_discovered() {
        let providers = env([]).makeClaudeProviders(cacheTTL: 60)
        #expect(providers.map(\.instanceKey.storageKey) == ["anthropic"])
    }

    @Test("one provider per discovered account, default first")
    func per_account() {
        let providers = env([account(nil, account: nil, dir: "/h/.claude"),
                             account("work", account: "t3st0001", dir: "/h/.claude-work")])
            .makeClaudeProviders(cacheTTL: 60)
        defer { cleanup(providers) }
        #expect(providers.map(\.instanceKey.storageKey) == ["anthropic", "anthropic.t3st0001"])
        #expect(providers.last?.accountLabel == "work")
    }

    @Test("with the default folder logged out there is no default card")
    func extras_only() {
        let providers = env([account("work", account: "t3st0002", dir: "/h/.claude-work")])
            .makeClaudeProviders(cacheTTL: 60)
        defer { cleanup(providers) }
        #expect(providers.map(\.instanceKey.storageKey) == ["anthropic.t3st0002"])
    }

    @Test("an extra account logs back in through its own config folder")
    func relogin_command() throws {
        let provider = try AnthropicProvider(account: account("work", account: "t3st0003", dir: "/h/.claude-work"))
        defer { cleanup([provider]) }
        #expect(provider.reloginCommand == "CLAUDE_CONFIG_DIR=/h/.claude-work claude auth login")
        #expect(try AnthropicProvider(cacheTTL: 60).reloginCommand == "claude auth login")
    }

    @Test("a folder path with shell metacharacters is single-quoted")
    func shell_quoting() {
        #expect(AnthropicProvider.shellQuoted("/h/.claude-work") == "/h/.claude-work")
        #expect(AnthropicProvider.shellQuoted("/Volumes/My Disk/c") == "'/Volumes/My Disk/c'")
        #expect(AnthropicProvider.shellQuoted("/a/it's;rm -rf") == "'/a/it'\\''s;rm -rf'")
        #expect(AnthropicProvider.shellQuoted("/x\u{0D4E};/usr/bin/id") == "'/x\u{0D4E};/usr/bin/id'")
    }
}

@MainActor
@Suite("Claude multi-account — analytics and discovery watcher", .serialized)
struct ClaudeMultiAccountAnalyticsTests {
    private let work = ProviderInstanceKey(vendor: .anthropic, account: "aaaa1111")

    @Test("each account gets its own analytics summary next to the vendor total")
    func account_summaries() async {
        let main = ProviderInstanceKey(vendor: .anthropic)
        let store = AnalyticsStore(
            estimatesProvider: { [.anthropic: CostEstimate(usdToday: 3, usdLast7Days: 30)] },
            accountsProvider: { [
                .init(key: main, name: "main", estimate: CostEstimate(usdToday: 1, usdLast7Days: 10), snapshot: nil),
                .init(key: self.work, name: "work", estimate: CostEstimate(usdToday: 2, usdLast7Days: 20), snapshot: nil),
            ] })
        store.timeframe = .weekly
        await drainMainQueue()
        await store.historyReloadTask?.value
        let accounts = store.accountSummaries[.anthropic] ?? []
        #expect(accounts.map(\.id) == ["anthropic", "anthropic.aaaa1111"])
        #expect(accounts.map(\.summary.totalCostUSD) == [10, 20])
        #expect(store.snapshot?.vendorSummaries.first?.totalCostUSD == 30)
    }

    @Test("\"All\" takes quota and history from one account, the most used")
    func all_uses_one_account_for_quota() async {
        let main = ProviderInstanceKey(vendor: .anthropic)
        func snap(_ pct: Double) -> VendorSnapshot {
            .zai(ZAISnapshot(session: UsageWindow(label: "Session", utilizationPercent: pct)))
        }
        let now = Date().timeIntervalSince1970
        let workKey = work
        let store = AnalyticsStore(
            estimatesProvider: { [.anthropic: CostEstimate(usdToday: 3, usdLast7Days: 30)] },
            snapshotsProvider: { [.anthropic: snap(10)] },
            historyProvider: { _ in [UsageHistoryStore.Sample(at: now - 60, max: 10)] },
            accountsProvider: { [
                .init(key: main, name: "main", estimate: nil, snapshot: snap(10)),
                .init(key: workKey, name: "work", estimate: nil, snapshot: snap(70)),
            ] },
            accountHistoryProvider: { key in
                key == workKey ? [UsageHistoryStore.Sample(at: now - 60, max: 70)] : []
            })
        store.timeframe = .weekly
        await drainMainQueue()
        await store.historyReloadTask?.value
        let all = store.snapshot?.vendorSummaries.first { $0.vendor == .anthropic }
        #expect(all?.totalUsagePercent == 70)
        #expect(all?.usageHistory.map(\.max) == [70])
    }

    @Test("the quota account breaks a tie toward the first (default) account")
    func quota_account_tie() {
        let main = ProviderInstanceKey(vendor: .anthropic)
        let pick = AnalyticsStore.quotaAccount([
            .init(key: main, name: "main", estimate: nil, snapshot: nil),
            .init(key: work, name: "work", estimate: nil, snapshot: nil),
        ])
        #expect(pick?.key == main)
    }

    private func account(_ key: ProviderInstanceKey) -> ClaudeAccount {
        ClaudeAccount(instanceKey: key, label: key.account, configDir: URL(fileURLWithPath: "/h"),
                      keychainService: "s")
    }

    @Test("an unchanged account set raises nothing")
    func watcher_unchanged() async {
        let launch = [account(ProviderInstanceKey(vendor: .anthropic))]
        let watcher = ClaudeAccountWatcher(launchAccounts: launch, discover: { launch })
        watcher.check()
        await watcher.pendingCheck?.value
        expectFalse(watcher.accountsChanged)
    }

    @Test("a new account raises the relaunch banner")
    func watcher_changed() async {
        let launch = [account(ProviderInstanceKey(vendor: .anthropic))]
        let now = launch + [account(work)]
        let watcher = ClaudeAccountWatcher(launchAccounts: launch, discover: { now })
        watcher.check()
        await watcher.pendingCheck?.value
        expectTrue(watcher.accountsChanged)
        watcher.dismiss()
        expectFalse(watcher.accountsChanged)
    }

    @Test("a check right after dismissing does not raise the same change again")
    func watcher_dismiss_adopts_seen_set() async {
        let launch = [account(ProviderInstanceKey(vendor: .anthropic))]
        let now = launch + [account(work)]
        let watcher = ClaudeAccountWatcher(launchAccounts: launch, discover: { now })
        watcher.check()
        await watcher.pendingCheck?.value
        watcher.dismiss()
        watcher.check()
        await watcher.pendingCheck?.value
        expectFalse(watcher.accountsChanged)
    }
}
