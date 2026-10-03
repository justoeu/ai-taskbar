import SwiftUI
import AppKit
import AiTaskbarCore

public struct PopoverContentView: View {
    private enum Overlay: Equatable {
        case status
        case analytics
        case about
        case settings
    }

    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var statusStore: ServiceStatusStore
    @EnvironmentObject var loginItem: LoginItemService
    @EnvironmentObject var cost: CostEstimator
    @EnvironmentObject var analyticsStore: AnalyticsStore
    @EnvironmentObject var configWatcher: ConfigWatcher
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var updates: UpdateChecker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the opacity dissolve when the popover opens.
    @State private var hasAppeared = false
    @State private var overlay: Overlay?
    @FocusState private var statusButtonFocused: Bool
    public var onQuit: () -> Void

    public init(onQuit: @escaping () -> Void = {}) {
        self.onQuit = onQuit
    }

    static let scrollTopID = "popover-scroll-top"
    static let appearDuration: TimeInterval = 0.12

    /// The first LLM card, or the top anchor when the list is empty.
    private var firstCardID: AnyHashable {
        store.sortedVendors.first.map { AnyHashable($0.vendorId) } ?? AnyHashable(Self.scrollTopID)
    }

    public var body: some View {
        ZStack {
            // Solid background — `MenuBarExtra(.window)` defaults to a
            // vibrancy/translucent material, which makes the popover hard to
            // read when bright content sits behind it. `windowBackgroundColor`
            // adapts to light/dark mode.
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                Divider()
                if configWatcher.configChanged || settingsViewModel.didSaveSuccessfully {
                    configChangedBanner
                    Divider()
                }
                if updates.isUpdateBannerVisible {
                    updateAvailableBanner
                    Divider()
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        // Fallback anchor when the list is empty.
                        Color.clear.frame(height: 0).id(Self.scrollTopID)
                        VStack(alignment: .leading, spacing: 12) {
                            if store.sortedVendors.isEmpty {
                                emptyState
                            } else {
                                // Reorder with ↑/↓ on each card. Drag-and-drop does
                                // not work reliably inside MenuBarExtra windows.
                                ForEach(store.sortedVendors) { vm in
                                    VendorSectionView(
                                        vm: vm,
                                        thresholds: store.thresholds,
                                        cost: cost,
                                        onOpenAnalytics: { vendorId in
                                            analyticsStore.targetVendor = vendorId
                                            overlay = .analytics
                                        }
                                    )
                                    .id(vm.vendorId)
                                }
                            }
                        }
                        .padding(12)
                        .animation(.easeInOut(duration: 0.15), value: store.sortedVendors.map(\.id))
                    }
                    .onChange(of: store.focusedVendor) { target in
                        guard let target else { return }
                        overlay = nil
                        if let vm = store.vendorVM(target), !vm.isExpanded {
                            vm.isExpanded = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(target, anchor: .top)
                            }
                        }
                    }
                    .onAppear {
                        store.isPopoverPresented = true
                        // An accessory app is not activated by opening its
                        // menu-bar window, so keys (Esc) would go to the
                        // previous app. Activate, then listen for Esc.
                        NSApp.activate(ignoringOtherApps: true)
                        PopoverKeyMonitor.shared.start()
                        hasAppeared = false
                        withAnimation(reduceMotion ? nil : .easeOut(duration: Self.appearDuration)) {
                            hasAppeared = true
                        }
                        guard let focused = store.consumeFocusedVendor() else {
                            // Opened from the main icon: always anchor on the
                            // FIRST LLM of the list, never where the last
                            // focused LLM left it. No animation — the window
                            // is fading in already. Re-applied on the next
                            // runloop turn, after SwiftUI has laid out.
                            let first = firstCardID
                            proxy.scrollTo(first, anchor: .top)
                            // Re-applied after layout settles: a real click can
                            // show the window before the ScrollView is sized.
                            for delay in [0.05, 0.15] {
                                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                    proxy.scrollTo(first, anchor: .top)
                                }
                            }
                            return
                        }
                        overlay = nil
                        if let vm = store.vendorVM(focused), !vm.isExpanded {
                            vm.isExpanded = true
                        }
                        let target = AnyHashable(focused)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(target, anchor: .top)
                            }
                        }
                    }
                    .onDisappear {
                        store.isPopoverPresented = false
                        PopoverKeyMonitor.shared.stop()
                        // Reopening always starts on the home screen, never on
                        // the About / Analytics / Status / Settings page it
                        // was closed from.
                        overlay = nil
                        analyticsStore.targetVendor = nil
                        // Reset while hidden, so the next open from the main
                        // icon already starts at the first LLM even if the
                        // scroll on appear loses a race with layout.
                        proxy.scrollTo(firstCardID, anchor: .top)
                        hasAppeared = false
                        PinnedStatusItemManager.shared.clearLastFocusedPinnedVendor()
                    }
                }
                Divider()
                footerBar
            }
            // Opacity-only dissolve on open: nothing moves, so no layout pass
            // competes with the animation. A window-level fade (with a delayed
            // close) and a small drop were both tried and read as stuttering.
            .opacity(hasAppeared || reduceMotion ? 1 : 0)

            .allowsHitTesting(overlay == nil && store.pinLimitAlert == nil)
            .disabled(overlay != nil || store.pinLimitAlert != nil)
            .accessibilityHidden(overlay != nil || store.pinLimitAlert != nil)

            if let overlay {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { dismissOverlay() }
                    .accessibilityHidden(true)
                switch overlay {
                case .status:
                    StatusPanelView { dismissOverlay(restoreStatusFocus: true) }
                        .environmentObject(statusStore)
                        .transition(overlayTransition)
                case .analytics:
                    AnalyticsView { self.overlay = nil }
                        .environmentObject(analyticsStore)
                        .environmentObject(store)
                        .transition(overlayTransition)
                case .about:
                    AboutView(
                        onDone: { self.overlay = nil },
                        onQuit: onQuit
                    )
                    .transition(overlayTransition)
                case .settings:
                    SettingsView { self.overlay = nil }
                        .environmentObject(settingsViewModel)
                        .transition(overlayTransition)
                }
            }

            if let alertInfo = store.pinLimitAlert {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                            store.pinLimitAlert = nil
                        }
                    }
                    .accessibilityHidden(true)

                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)

                    VStack(spacing: 6) {
                        Text(alertInfo.title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(alertInfo.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                            store.pinLimitAlert = nil
                        }
                    } label: {
                        Text(L10n.localizedString("pin_limit_reached_ok"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(20)
                .frame(width: 300)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .transition(overlayTransition)
                .zIndex(200)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: overlay)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: store.pinLimitAlert != nil)
        // Esc normally never reaches this: PopoverKeyMonitor closes the
        // popover first. It passes Esc through only while a modal is up, and
        // then this dismisses the pin-limit alert (About handles its own).
        .onExitCommand {
            if store.pinLimitAlert != nil {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    store.pinLimitAlert = nil
                }
            } else {
                overlay = nil
            }
        }
        .background(PopoverWindowReader { PopoverKeyMonitor.shared.window = $0 })
        .onChange(of: store.pinLimitAlert != nil) { PopoverKeyMonitor.shared.pinLimitAlertShown = $0 }
    }

    private var headerBar: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(.tint)
                L10n.text("app_name")
                    .font(.headline)
                Spacer()
                // Forward countdown to the next scheduled refresh. The format
                // is "Próx. em M:SS" computed from `lastRefreshedAt + interval`
                // (the scheduler's cadence). When a fetch is in flight (any
                // vendor `.loading`) we swap for "Atualizando…" instead of
                // showing 0:00 with no movement.
                //
                // `TimelineView` re-renders every 1 s. The `from:` anchor
                // MUST be a fixed epoch (not `.now`) so the schedule is
                // deterministic across popover open/close cycles.
                TimelineView(.periodic(from: Self.scheduleAnchor, by: 1)) { context in
                    countdownLabel(now: context.date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // 1. Refresh
                Button {
                    store.refreshAll(forceRefresh: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10n.localizedString("refresh_all_help"))

                // 2. Status
                if !statusStore.rows.isEmpty {
                    Button {
                        overlay = .status
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: ServiceStatusPresentation.headerSymbol)
                                .foregroundStyle(.primary)
                            Image(systemName: ServiceStatusPresentation.symbol(
                                for: statusStore.overallLevel
                            ))
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(statusStore.overallLevel.statusColor)
                            .background(
                                Circle()
                                    .fill(Color(NSColor.windowBackgroundColor))
                                    .padding(-1)
                            )
                            .offset(x: 3, y: 3)
                        }
                        .frame(width: 20, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .focused($statusButtonFocused)
                    .help(L10n.localizedString("service_status_help"))
                    .accessibilityLabel(L10n.localizedString("service_status_ax_label"))
                    .accessibilityValue(statusAccessibilityValue)
                    .accessibilityHint(L10n.localizedString("service_status_ax_hint"))
                }

                // 3. Analytics
                Button {
                    analyticsStore.targetVendor = nil
                    overlay = .analytics
                } label: {
                    Image(systemName: AnalyticsView.headerSymbol)
                }
                .buttonStyle(.borderless)
                .help(L10n.localizedString("analytics_toolbar_button"))

                // 4. About
                Button {
                    overlay = .about
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.localizedString("about_help"))
            }
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                L10n.text("menu_bar_hint")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { loginItem.isRegistered },
                set: { _ in loginItem.toggle() }
            )) {
                L10n.text("open_at_login")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(loginItem.statusDescription)

            Spacer()

            Button {
                overlay = .settings
            } label: {
                Label(L10n.localizedString("settings"), systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(L10n.localizedString("settings_help"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .font(.subheadline)
    }

    /// Non-intrusive yellow banner shown when config.toml changes on disk.
    /// Most settings (refresh interval, language, vendor enabled flags,
    /// cache TTL, TLS pinning) are captured at launch; a relaunch is the
    /// only consistent way to reflect them.
    private var configChangedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.yellow)
            L10n.text("config_changed_banner")
                .font(.subheadline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                configWatcher.relaunch()
            } label: {
                L10n.text("relaunch")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                configWatcher.dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L10n.localizedString("dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }

    @ViewBuilder
    private var updateAvailableBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)

            switch updates.status {
            case .updateAvailable(let release):
                Text(String(format: L10n.localizedString("update_banner_available_fmt"), release.tag))
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    updates.download(release)
                } label: {
                    L10n.text("update_banner_button")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    updates.dismissCurrentUpdate()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L10n.localizedString("update_banner_dismiss"))

            case .downloading(let progress, _):
                L10n.text("update_banner_downloading")
                    .font(.subheadline)
                    .lineLimit(1)
                ProgressView(value: progress > 0 ? progress : nil)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 80)
                Spacer(minLength: 4)

            case .downloaded(let localURL, _):
                L10n.text("update_banner_ready")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([localURL])
                } label: {
                    L10n.text("update_banner_open")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    updates.dismissCurrentUpdate()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L10n.localizedString("update_banner_dismiss"))

            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.localizedString("no_providers_enabled"),
                  systemImage: "exclamationmark.triangle")
                .font(.subheadline)
            L10n.text("no_providers_hint")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Single shared formatter — process-lifetime, one allocation.
    /// Locale captures the L10n override at first use (which is after
    /// `AiTaskbarApp.init` has already applied the override). Re-aligning
    /// the formatter with a language change would require a relaunch, which
    /// is the documented behavior anyway.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = L10n.effectiveLocale
        return f
    }()

    /// Fixed anchor for the `TimelineView` periodic schedule. Using a
    /// constant epoch (rather than `.now`) means the schedule is
    /// deterministic across popover open/close cycles — the next tick is
    /// always at most one interval away, regardless of when the view mounts.
    private static let scheduleAnchor = Date(timeIntervalSinceReferenceDate: 0)

    /// Header countdown: "Próx. em 4:59" while the next scheduled refresh
    /// approaches; "Atualizando…" while at least one vendor's fetch is in
    /// flight; "Aguardando rate-limit…" while RefreshScheduler is sleeping
    /// out the 60 s back-off after a 429; empty otherwise. Pure function of
    /// `store` + `now` so the surrounding `TimelineView` controls the
    /// 1-second re-render cadence.
    @ViewBuilder
    private func countdownLabel(now: Date) -> some View {
        if store.isAnyVendorLoading {
            Text(Self.refreshingNowText)
        } else if store.isInRateLimitBackoff {
            Text(Self.rateLimitWaitingText)
        } else if let tick = store.lastScheduledTickAt {
            let elapsed = now.timeIntervalSince(tick)
            let remaining = max(0, store.refreshIntervalSeconds - elapsed)
            let (minutes, seconds) = DurationParts.minutesSeconds(remaining)
            // Manual concat avoids String(format:) machinery + a temporary
            // String allocation per tick. With the popover open for 5 min
            // that's ~300 saved Format scans + alloc/release cycles.
            let mmss = "\(minutes):\(seconds < 10 ? "0" : "")\(seconds)"
            Text(String(format: Self.nextRefreshInFmt, mmss))
        } else {
            // No fresh fetch on record yet — say nothing rather than
            // claiming a countdown we can't honor.
            EmptyView()
        }
    }

    // L10n.localizedString does an uncached Bundle lookup per call. These
    // three keys are read up to 1×/s by the TimelineView while the popover
    // is open, so resolve them once at type initialization. Language change
    // requires a relaunch anyway (per `L10n.languageOverride` semantics),
    // so a static cache is honest.
    private static let refreshingNowText = L10n.localizedString("refreshing_now")
    private static let rateLimitWaitingText = L10n.localizedString("rate_limit_waiting")
    private static let nextRefreshInFmt = L10n.localizedString("next_refresh_in_fmt")

    private var overlayTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity)
    }

    private func dismissOverlay(restoreStatusFocus: Bool = false) {
        overlay = nil
        guard restoreStatusFocus else { return }
        Task { @MainActor in
            await Task.yield()
            statusButtonFocused = true
        }
    }

    private var statusAccessibilityValue: String {
        let statuses = statusStore.rows.map { row in
            row.state.displayStatus ?? ServiceStatusPresentation.placeholder(for: row.vendorId)
        }
        let affected = statuses.filter {
            ![ServiceStatusLevel.operational, .unknown].contains($0.level)
        }.count
        let unknown = statuses.filter { $0.level == .unknown }.count
        let automatic = statuses.filter { $0.coverage != .linkOnly }.count
        return L10n.localizedString(
            "service_status_ax_value_fmt",
            affected,
            unknown,
            automatic
        )
    }
}
