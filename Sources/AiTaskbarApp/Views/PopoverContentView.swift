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
                // `TimelineView` forces a re-render every 1 s using the
                // schedule's `context.date` as "now" — without it the relative
                // string ("há 42 seg") would freeze at whatever the popover
                // last rendered, because nothing in `store` changes between
                // fetches.
                //
                // The `from:` anchor MUST be a fixed epoch, NOT `.now`. With
                // `.now`, every popover open re-anchors the schedule so the
                // first tick is `interval` seconds away — if the user closes
                // and reopens faster than `interval`, they never see a tick
                // and the timer appears frozen.
                if let when = store.lastRefreshedAt {
                    TimelineView(.periodic(from: Self.scheduleAnchor, by: 1)) { context in
                        Text(String(
                            format: L10n.localizedString("updated_ago_fmt"),
                            Self.relativeFormatter.localizedString(
                                for: when, relativeTo: context.date)
                        ))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
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
}
