import SwiftUI
import AppKit
import AiTaskbarCore

public struct PopoverContentView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var loginItem: LoginItemService
    @EnvironmentObject var cost: CostEstimator
    @EnvironmentObject var configWatcher: ConfigWatcher
    @State private var showAbout = false
    public var onOpenConfig: () -> Void
    public var onQuit: () -> Void

    public init(onOpenConfig: @escaping () -> Void = {}, onQuit: @escaping () -> Void = {}) {
        self.onOpenConfig = onOpenConfig
        self.onQuit = onQuit
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
                if configWatcher.configChanged {
                    configChangedBanner
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.vendors.isEmpty {
                            emptyState
                        } else {
                            ForEach(store.vendors) { vm in
                                VendorSectionView(vm: vm,
                                                  thresholds: store.thresholds,
                                                  cost: cost)
                            }
                        }
                    }
                    .padding(12)
                }
                Divider()
                footerBar
            }

            // About overlay — rendered IN-POPOVER (not via .sheet) so the
            // Done button doesn't bubble up and dismiss the menu bar window.
            if showAbout {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { showAbout = false }
                AboutView { showAbout = false }
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showAbout)
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
                Button {
                    showAbout = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.localizedString("about_help"))
                Button {
                    store.refreshAll(forceRefresh: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10n.localizedString("refresh_all_help"))
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
            Button {
                onOpenConfig()
            } label: {
                Label(L10n.localizedString("config"), systemImage: "doc.text")
            }
            .buttonStyle(.borderless)
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
            Button(role: .destructive) {
                onQuit()
            } label: {
                Label(L10n.localizedString("quit"), systemImage: "power")
            }
            .buttonStyle(.borderless)
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
    /// flight; empty otherwise (e.g. the very first refresh hasn't returned
    /// a fresh outcome yet — `lastRefreshedAt` is nil, so we have nothing
    /// to count down from). Pure function of `store` + `now` so the
    /// surrounding `TimelineView` controls the 1-second re-render cadence.
    @ViewBuilder
    private func countdownLabel(now: Date) -> some View {
        if store.isAnyVendorLoading {
            Text(L10n.localizedString("refreshing_now"))
        } else if let tick = store.lastScheduledTickAt {
            // Anchor on the scheduler tick, not on `lastRefreshedAt`.
            // `lastRefreshedAt` only advances when a fetch returns truly
            // fresh data (cacheAge <= 1) — meaning a tick that hit the
            // cache boundary or 429'd into the stale fallback would never
            // reset the countdown and the label would stick at 0:00 until
            // a successful network fetch landed.
            let elapsed = now.timeIntervalSince(tick)
            let remaining = max(0, store.refreshIntervalSeconds - elapsed)
            let minutes = Int(remaining) / 60
            let seconds = Int(remaining) % 60
            Text(String(
                format: L10n.localizedString("next_refresh_in_fmt"),
                String(format: "%d:%02d", minutes, seconds)
            ))
        } else {
            // No fresh fetch on record yet — say nothing rather than
            // claiming a countdown we can't honor.
            EmptyView()
        }
    }
}
