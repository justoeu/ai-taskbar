import SwiftUI
import AppKit
import AiTaskbarCore

public struct PopoverContentView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var loginItem: LoginItemService
    @EnvironmentObject var cost: CostEstimator
    @State private var showAbout = false
    public var onOpenConfig: () -> Void
    public var onQuit: () -> Void

    public init(onOpenConfig: @escaping () -> Void = {}, onQuit: @escaping () -> Void = {}) {
        self.onOpenConfig = onOpenConfig
        self.onQuit = onQuit
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                headerBar
                Divider()
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
                // `TimelineView` forces a re-render every 30 s using the
                // schedule's `context.date` as "now" — without it the relative
                // string ("há 42 seg") would freeze at whatever the popover
                // last rendered, because nothing in `store` changes between
                // fetches.
                if let when = store.lastRefreshedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(String(
                            format: L10n.localizedString("updated_ago_fmt"),
                            Self.relativeFormatter.localizedString(
                                for: when, relativeTo: context.date)
                        ))
                            .font(.caption)
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
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                L10n.text("menu_bar_hint")
                    .font(.caption2)
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
        .font(.caption)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.localizedString("no_providers_enabled"),
                  systemImage: "exclamationmark.triangle")
                .font(.subheadline)
            L10n.text("no_providers_hint")
                .font(.caption)
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
}
