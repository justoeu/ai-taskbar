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
    @StateObject private var configWatcher: ConfigWatcher
    @StateObject private var settingsViewModel: SettingsViewModel
    private let env: AppEnvironment

    init() {
        var env = AppEnvironment.live()
        _updates = StateObject(wrappedValue: UpdateChecker(config: env.config.updates))
        let watcherPath = (try? Paths.configFile())
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ai-taskbar-config.toml")
        let configWatcher = ConfigWatcher(path: watcherPath)
        _configWatcher = StateObject(wrappedValue: configWatcher)
        // Wire ConfigLoader's post-save hook so the ConfigWatcher doesn't
        // surface a "Config changed — relaunch" banner for writes the
        // Settings UI itself just made (it surfaces the banner via
        // SettingsViewModel.didSaveSuccessfully instead).
        //
        // `onAfterSave` is `@Sendable () -> Void` (called from inside
        // ConfigLoader which is a Sendable struct). In practice the call
        // always lands on MainActor because the SettingsViewModel.save()
        // path that triggers it is @MainActor — `assumeIsolated` asserts
        // that invariant and lets us reach the @MainActor method.
        env.configLoader.onAfterSave = { [weak configWatcher] in
            MainActor.assumeIsolated {
                configWatcher?.adoptCurrentAsBaseline()
            }
        }
        // Apply language override from config BEFORE any view reads strings,
        // so the very first render uses the right locale.
        L10n.languageOverride = env.config.ui.language
        let notifications = NotificationService(config: env.config.notifications)
        let vendors = env.makeProviders().map {
            VendorViewModel(provider: $0, notifications: notifications)
        }
        let store = UsageStore(
            vendors: vendors,
            primary: env.config.ui.primary,
            thresholds: env.config.thresholds,
            refreshIntervalSeconds: env.config.ui.refreshIntervalSeconds
        )
        let scheduler = RefreshScheduler(store: store,
                                         interval: env.config.ui.refreshIntervalSeconds)
        // Kick off the refresh + compact loops from launch so usage starts
        // accumulating without requiring the user to open the popover first.
        scheduler.start()
        _settingsViewModel = StateObject(wrappedValue: SettingsViewModel(
            config: env.config, configLoader: env.configLoader))
        self.env = env
        _store = StateObject(wrappedValue: store)
        _scheduler = StateObject(wrappedValue: scheduler)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView(
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .environmentObject(store)
            .environmentObject(loginItem)
            .environmentObject(cost)
            .environmentObject(updates)
            .environmentObject(configWatcher)
            .environmentObject(settingsViewModel)
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
}
