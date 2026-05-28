import SwiftUI
import AppKit
import AiTaskbarCore

public struct VendorSectionView: View {
    @ObservedObject var vm: VendorViewModel
    public let thresholds: ThresholdsConfig
    @ObservedObject var cost: CostEstimator

    /// User preference (persisted via UserDefaults). Disabled vendors are
    /// rendered as forced-collapsed regardless of this value — `effectiveExpanded`
    /// is what the view actually reads.
    ///
    /// We deliberately do NOT use `@AppStorage` here. Initializing `@AppStorage`
    /// from inside `init` causes SwiftUI to re-construct the wrapper on every
    /// parent re-render, which in turn invalidates the view in a tight loop
    /// (visible as a permanent "Loading…" spinner that never resolves).
    @State private var userExpanded: Bool

    private static func expansionKey(for vendor: VendorId) -> String {
        "expanded_\(vendor.rawValue)"
    }

    public init(vm: VendorViewModel,
                thresholds: ThresholdsConfig,
                cost: CostEstimator) {
        self.vm = vm
        self.thresholds = thresholds
        self.cost = cost
        let key = Self.expansionKey(for: vm.vendorId)
        let saved = (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
        _userExpanded = State(initialValue: saved)
    }

    private func persistExpansion(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.expansionKey(for: vm.vendorId))
    }

    /// True when this vendor is "disabled" (no credentials).
    private var isDisabled: Bool {
        if case .failed(let err, _) = vm.state, err.isDisabled { return true }
        return false
    }

    private var effectiveExpanded: Bool {
        // Vendors without credentials stay folded regardless of preference.
        isDisabled ? false : userExpanded
    }

    public var body: some View {
        let state = vm.state
        VStack(alignment: .leading, spacing: 8) {
            header(state: state)
            if effectiveExpanded {
                content(state: state)
                if !vm.history.isEmpty {
                    SparklineView(samples: vm.history, thresholds: thresholds)
                }
                costFooter
            } else if isDisabled {
                disabledHint
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .animation(.easeInOut(duration: 0.15), value: effectiveExpanded)
    }

    @ViewBuilder
    private var disabledHint: some View {
        Label(L10n.localizedString("no_credentials_short"),
              systemImage: "key.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var costFooter: some View {
        if let estimate = cost.byVendor[vm.vendorId],
           estimate.usdToday > 0 || estimate.usdLast7Days > 0 {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                costRow(labelKey: "today_label",
                        systemImage: "calendar",
                        value: estimate.usdToday)
                costRow(labelKey: "weekly_label",
                        systemImage: "chart.bar",
                        value: estimate.usdLast7Days,
                        trailingNote: estimate.isApproximate
                            ? L10n.localizedString("approximate_short")
                            : nil,
                        trailingHelp: estimate.note
                            ?? L10n.localizedString("approximate_help"))
                modelBreakdownDetailed(for: estimate)
            }
        }
    }

    /// One row of the cost summary: label + icon on the left, monospaced
    /// USD value pinned to the right, optional "aprox." note after the
    /// value (with help tooltip).
    @ViewBuilder
    private func costRow(labelKey: String,
                         systemImage: String,
                         value: Double,
                         trailingNote: String? = nil,
                         trailingHelp: String? = nil) -> some View {
        HStack(spacing: 6) {
            Label(L10n.localizedString(labelKey), systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(String(format: "$%.2f", value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let note = trailingNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(trailingHelp ?? "")
            }
        }
    }

    /// Combined breakdown showing both today and the 7-day window. Today
    /// might only have 1 model (what you used right now); 7d typically has
    /// more (everything in your recent history). Showing both removes the
    /// "where did the $7k come from?" mystery.
    @ViewBuilder
    private func modelBreakdownDetailed(for estimate: CostEstimate) -> some View {
        let allModels: Set<String> = Set(estimate.modelBreakdownToday.keys)
            .union(estimate.modelBreakdownLast7Days.keys)
        if !allModels.isEmpty {
            let rows: [ModelRow] = allModels.map { model in
                ModelRow(
                    name: model,
                    usdToday: estimate.modelBreakdownToday[model] ?? 0,
                    usd7d:   estimate.modelBreakdownLast7Days[model] ?? 0
                )
            }
            .sorted { ($0.usd7d, $0.usdToday) > ($1.usd7d, $1.usdToday) }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    L10n.text("models_header")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    modelRow(row,
                             totalToday: estimate.usdToday,
                             total7d: estimate.usdLast7Days)
                }
            }
            .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private func modelRow(_ row: ModelRow, totalToday: Double, total7d: Double) -> some View {
        let todayPct = totalToday > 0 ? Int((row.usdToday / totalToday * 100).rounded()) : 0
        let weekPct  = total7d > 0    ? Int((row.usd7d   / total7d   * 100).rounded()) : 0
        HStack(spacing: 0) {
            Text(Self.shortModelName(row.name))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if row.usdToday > 0 {
                Text(String(format: "$%.2f", row.usdToday))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(String(format: " (%d%%)", todayPct))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text("—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(" / ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            if row.usd7d > 0 {
                Text(String(format: "$%.2f", row.usd7d))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(String(format: " (%d%%)", weekPct))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text("—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private struct ModelRow: Identifiable {
        let name: String
        let usdToday: Double
        let usd7d: Double
        var id: String { name }
    }

    /// Strips noisy model-name prefixes for the inline display
    /// ("claude-opus-4-7" → "opus-4-7", "gpt-5-codex" stays as-is).
    private static func shortModelName(_ model: String) -> String {
        if model.hasPrefix("claude-") {
            return String(model.dropFirst("claude-".count))
        }
        return model
    }

    @ViewBuilder
    private func header(state: VendorViewModel.State) -> some View {
        HStack {
            // Chevron toggles user preference. Disabled when there are no
            // credentials — the visual chevron is hidden in that case.
            if !isDisabled {
                Button {
                    userExpanded.toggle()
                    persistExpansion(userExpanded)
                } label: {
                    Image(systemName: effectiveExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(L10n.localizedString(
                    effectiveExpanded ? "collapse_fmt" : "expand_fmt",
                    vm.vendorId.displayName))
            } else {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .help(L10n.localizedString("locked_help"))
            }
            Button {
                if let url = vm.vendorId.dashboardURL {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(vm.vendorId.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if vm.vendorId.dashboardURL != nil {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let plan = state.outcome?.snapshot.planLabel {
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .modifier(HelpIfPresent(text: vm.vendorId.dashboardURL.map {
                L10n.localizedString("open_dashboard_fmt", $0.host ?? "dashboard")
            }))
            Spacer()
            statusIndicator(state: state)
            if !isDisabled {
                Button {
                    vm.refresh(forceRefresh: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10n.localizedString("refresh_vendor_fmt", vm.vendorId.displayName))
            }
        }
    }

    private struct HelpIfPresent: ViewModifier {
        let text: String?
        func body(content: Content) -> some View {
            if let text, !text.isEmpty {
                content.help(text)
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private func statusIndicator(state: VendorViewModel.State) -> some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small)
        case .ok(let outcome) where outcome.isStale:
            // Tooltip now surfaces WHY the data is stale (last error message)
            // when available — credential ACL mismatch, schema drift, etc.
            // Falls back to the generic "stale" hint if no error captured.
            let detail = outcome.lastError?.body ?? L10n.localizedString("stale_help")
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(detail)
        case .failed(let err, _) where err.isDisabled:
            Image(systemName: "key.slash")
                .foregroundStyle(.secondary)
                .help(L10n.localizedString("no_credentials_help"))
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .help(L10n.localizedString("last_fetch_failed_help"))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func content(state: VendorViewModel.State) -> some View {
        switch state {
        case .idle:
            L10n.text("waiting_first_refresh")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .loading where state.outcome == nil:
            L10n.text("loading")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .loading, .ok:
            if let snap = state.outcome?.snapshot {
                if snap.windows.isEmpty {
                    L10n.text("no_usage_windows")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    renderSnapshot(snap)
                }
            }

        case .failed(let err, let fallback):
            VStack(alignment: .leading, spacing: 6) {
                if err.isDisabled {
                    Label(L10n.localizedString("no_credentials_for_vendor_fmt",
                                               vm.vendorId.displayName),
                          systemImage: "key.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    L10n.text("no_credentials_hint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(err.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let snap = fallback?.snapshot, !snap.windows.isEmpty {
                    Divider()
                    L10n.text("showing_cached_data")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    renderSnapshot(snap)
                }
            }
        }
    }

    @ViewBuilder
    private func renderSnapshot(_ snap: VendorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snap.windows, id: \.label) { w in
                ProviderRowView(window: w, thresholds: thresholds)
            }
            extras(for: snap)
        }
    }

    @ViewBuilder
    private func extras(for snap: VendorSnapshot) -> some View {
        switch snap {
        case .anthropic(let s):
            if let extra = s.extraUsageUSD, extra > 0 {
                Label(L10n.localizedString("extra_usage_fmt", extra),
                      systemImage: "dollarsign.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .openai(let s):
            if let credits = s.creditsUSD {
                Label(L10n.localizedString("credits_fmt", credits),
                      systemImage: "dollarsign.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let range = s.messageCountRange {
                Label(range, systemImage: "message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .openrouter, .zai:
            EmptyView()
        case .kimi(let s):
            VStack(alignment: .leading, spacing: 2) {
                if let avail = s.availableUSD {
                    Label(L10n.localizedString("balance_fmt", avail),
                          systemImage: "dollarsign.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let voucher = s.voucherUSD, voucher > 0 {
                    Label(L10n.localizedString("voucher_fmt", voucher),
                          systemImage: "ticket")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let cash = s.cashUSD, cash > 0 {
                    Label(L10n.localizedString("cash_fmt", cash),
                          systemImage: "creditcard")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
