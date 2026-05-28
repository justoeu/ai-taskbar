import SwiftUI
import AppKit
import AiTaskbarCore
import AiTaskbarProviders

@main
struct AiTaskbarApp: App {
    @StateObject private var store: UsageStore
    @StateObject private var scheduler: RefreshScheduler
    @StateObject private var loginItem = LoginItemService()
    @StateObject private var cost = CostEstimator()
    @StateObject private var updates: UpdateChecker
    private let env: AppEnvironment

    init() {
        let env = AppEnvironment.live()
        _updates = StateObject(wrappedValue: UpdateChecker(config: env.config.updates))
        // Apply language override from config BEFORE any view reads strings,
        // so the very first render uses the right locale.
        L10n.languageOverride = env.config.ui.language
        let notifications = NotificationService(config: env.config.notifications)
        notifications.requestAuthorizationIfNeeded()
        let vendors = env.makeProviders().map {
            VendorViewModel(provider: $0, notifications: notifications)
        }
        let store = UsageStore(
            vendors: vendors,
            primary: env.config.ui.primary,
            thresholds: env.config.thresholds
        )
        let scheduler = RefreshScheduler(store: store,
                                         interval: env.config.ui.refreshIntervalSeconds)
        // Kick off the refresh + compact loops from launch so usage starts
        // accumulating without requiring the user to open the popover first.
        scheduler.start()
        self.env = env
        _store = StateObject(wrappedValue: store)
        _scheduler = StateObject(wrappedValue: scheduler)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView(
                onOpenConfig: { openConfig() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .environmentObject(store)
            .environmentObject(loginItem)
            .environmentObject(cost)
            .environmentObject(updates)
            .frame(width: 420, height: 540)
            .onAppear {
                // Scheduler is already running from init (see above).
                // These two are cheap on subsequent opens (idempotent /
                // debounced) and let the popover show fresh data on first view.
                loginItem.refresh()
                cost.refresh()
            }
        } label: {
            MenuBarLabelView(store: store, mode: env.config.ui.menuBarMode)
        }
        .menuBarExtraStyle(.window)
    }

    private func openConfig() {
        let url = (try? Paths.configFile()) ?? URL(fileURLWithPath: "/tmp/ai-taskbar-config.toml")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? env.configLoader.save(env.config)
        }
        NSWorkspace.shared.open(url)
    }
}
