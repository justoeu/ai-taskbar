import SwiftUI
import AiTaskbarCore

public struct StatusPanelView: View {
    @EnvironmentObject private var store: ServiceStatusStore
    @EnvironmentObject private var usageStore: UsageStore
    @FocusState private var closeButtonFocused: Bool
    public let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VendorOrderSyncBar(isOn: $store.syncVendorOrder)
            Divider()
            ScrollView {
                let rows = store.orderedRows(homeOrder: homeOrder)
                LazyVStack(spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        StatusVendorRowView(
                            row: row,
                            canMoveUp: index > 0,
                            canMoveDown: index < rows.count - 1,
                            onMove: { up in move(row.vendorId, up: up) }
                        )
                        .environmentObject(store)
                    }
                }
                .padding(12)
                .animation(.easeInOut(duration: 0.15), value: rows.map(\.id))
            }
            Divider()
            footer
        }
        .frame(width: 420, height: 540)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(radius: 20)
        )
        .focusSection()
        .onAppear { closeButtonFocused = true }
        .onChange(of: store.syncVendorOrder) { synced in
            // Turning sync off starts the independent order from the home one.
            if !synced { store.adoptHomeOrder(homeOrder) }
        }
        .onExitCommand(perform: onClose)
    }

    private var homeOrder: [VendorId] { usageStore.sortedVendors.map(\.vendorId) }

    /// Synced: moving here reorders the home screen too (same as Analytics).
    private func move(_ id: VendorId, up: Bool) {
        if store.syncVendorOrder {
            up ? usageStore.moveVendorUp(id) : usageStore.moveVendorDown(id)
        } else {
            store.moveVendor(id, up: up, homeOrder: homeOrder)
        }
    }

    /// Same layout as the Analytics header: feature icon, bold title,
    /// one caption line with the freshness inline, refresh on the right.
    /// "Back" lives in the footer.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: ServiceStatusPresentation.headerSymbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                L10n.text("service_status_title")
                    .font(.title3.weight(.bold))
                HStack(spacing: 4) {
                    L10n.text("service_status_last_six_hours")
                        .foregroundStyle(.secondary)
                    Text("•")
                        .foregroundStyle(store.isLoading ? .secondary : .tertiary)
                    if store.isLoading {
                        Text(L10n.localizedString("refreshing_now"))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text(headerFreshness)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }

            Spacer()

            Button {
                store.refreshAll(forceRefresh: true)
            } label: {
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
            .help(L10n.localizedString("service_status_refresh"))
            .accessibilityLabel(L10n.localizedString("service_status_refresh"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var headerFreshness: String {
        if !store.hasAutomaticSources {
            return L10n.localizedString("service_status_no_automatic_sources")
        }
        guard let completed = store.lastCompletedRefreshAt else {
            return L10n.localizedString("service_status_never_updated")
        }
        return L10n.localizedString(
            "service_status_updated_fmt",
            Self.timeFormatter.string(from: completed)
        )
    }

    /// Same symbols and colours as the rows, so the legend reads as a key,
    /// not a sentence. One line when it fits, two otherwise.
    private var legend: some View {
        let items = ServiceStatusPresentation.legend.map { entry in
            HStack(spacing: 4) {
                Image(systemName: ServiceStatusPresentation.symbol(for: entry.level))
                    .foregroundStyle(entry.level.statusColor)
                Text(L10n.localizedString(entry.key))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize()
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ForEach(items.indices, id: \.self) { items[$0] } }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) { ForEach(0..<3, id: \.self) { items[$0] } }
                HStack(spacing: 12) { ForEach(3..<items.count, id: \.self) { items[$0] } }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                legend
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "info.circle")
                    L10n.text("service_status_scope_note")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button(action: onClose) {
                    Label(L10n.localizedString("back"), systemImage: "chevron.backward")
                }
                .focused($closeButtonFocused)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.effectiveLocale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct StatusVendorRowView: View {
    @EnvironmentObject private var store: ServiceStatusStore
    let row: ServiceStatusStore.Row
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (_ up: Bool) -> Void
    @State private var isExpanded: Bool

    init(row: ServiceStatusStore.Row, canMoveUp: Bool, canMoveDown: Bool,
         onMove: @escaping (_ up: Bool) -> Void) {
        self.row = row
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.onMove = onMove
        let level = row.state.displayStatus?.level ?? .unknown
        _isExpanded = State(initialValue: level != .operational)
    }

    /// Same ↑/↓ affordance as the home and Analytics cards; outside the
    /// expand button so the two never nest.
    private var reorderButtons: some View {
        HStack(spacing: 2) {
            Button { onMove(true) } label: { Image(systemName: "chevron.up.circle") }
                .disabled(!canMoveUp)
                .help(L10n.localizedString("move_vendor_up_help"))
                .accessibilityLabel(L10n.localizedString("move_vendor_up_help"))
            Button { onMove(false) } label: { Image(systemName: "chevron.down.circle") }
                .disabled(!canMoveDown)
                .help(L10n.localizedString("move_vendor_down_help"))
                .accessibilityLabel(L10n.localizedString("move_vendor_down_help"))
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var status: VendorServiceStatus {
        row.state.displayStatus ?? ServiceStatusPresentation.placeholder(for: row.vendorId)
    }

    private var displayLevelKey: String {
        ServiceStatusPresentation.displayLevelKey(
            for: status,
            hasObservation: row.state.outcome != nil && !row.state.isStale
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: ServiceStatusPresentation.symbol(for: status.level))
                        .foregroundStyle(status.level.statusColor)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            VendorBrandIcon(vendorId: row.vendorId, size: 12)
                            Text(row.vendorId.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        Text(L10n.localizedString(displayLevelKey))
                        .font(.caption)
                        .foregroundStyle(status.level.statusColor)
                    }
                    Spacer(minLength: 4)
                    Text(L10n.localizedString(
                        ServiceStatusPresentation.coverageKey(for: status.coverage)
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.vendorId.displayName)
            .accessibilityValue(L10n.localizedString(displayLevelKey))
            .accessibilityHint(L10n.localizedString(
                isExpanded ? "service_status_collapse" : "service_status_expand"
            ))
            reorderButtons
            }

            stateNotice
            StatusTimelineView(status: status, now: .now)

            if isExpanded {
                details
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private var stateNotice: some View {
        switch row.state {
        case .loading:
            Label(L10n.localizedString("service_status_loading"), systemImage: "arrow.clockwise")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .ok(let outcome) where row.state.isStale:
            staleNotice(outcome: outcome)
        case .failed(_, let fallback):
            if let fallback {
                staleNotice(outcome: fallback)
            } else {
                HStack(spacing: 6) {
                    Label(L10n.localizedString("service_status_cold_error"),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 2)
                    Button(L10n.localizedString("service_status_retry")) {
                        store.refreshAll(forceRefresh: true)
                    }
                    .controlSize(.mini)
                }
            }
        case .idle:
            Text(L10n.localizedString("service_status_never_updated"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .ok, .unavailable:
            EmptyView()
        }
    }

    private func staleNotice(outcome: ServiceStatusOutcome) -> some View {
        Label(
            L10n.localizedString(
                "service_status_stale_fmt",
                Self.timeFormatter.string(from: outcome.fetchedAt)
            ),
            systemImage: "clock.badge.exclamationmark"
        )
        .font(.caption2)
        .foregroundStyle(.orange)
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !status.summary.isEmpty {
                Text(status.summary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status.incidents.isEmpty {
                Text(L10n.localizedString(
                    row.state.isStale ? "service_status_level_unknown"
                        : ServiceStatusPresentation.emptyStateKey(for: status.coverage)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(status.incidents) { incident in
                    IncidentDetailView(incident: incident, vendorId: row.vendorId)
                    if incident.id != status.incidents.last?.id { Divider() }
                }
            }
            if let page = ServiceStatusPresentation.safeURL(
                status.sourceURL ?? row.vendorId.statusPageURL,
                for: row.vendorId
            ) {
                Link(destination: page) {
                    Label(L10n.localizedString("service_status_open_page"),
                          systemImage: "safari")
                }
                .font(.caption)
            }
        }
        .transition(.opacity)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.effectiveLocale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct StatusTimelineView: View {
    let status: VendorServiceStatus
    let now: Date

    private var segments: [ServiceStatusTimelineSegment] {
        ServiceStatusPresentation.timelineSegments(for: status, now: now)
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(segment.level.statusColor.opacity(0.85))
                            .frame(width: max(
                                1,
                                proxy.size.width * (segment.endFraction - segment.startFraction)
                            ))
                            .offset(x: proxy.size.width * segment.startFraction)
                    }
                }
            }
            .frame(height: 9)
            HStack {
                L10n.text("service_status_minus_six_hours")
                Spacer()
                L10n.text("service_status_now")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.localizedString(
            "service_status_timeline_ax_fmt",
            accessibilityDurationSummary
        ))
    }

    private var accessibilityDurationSummary: String {
        let durations = ServiceStatusPresentation.durationByLevel(for: status, now: now)
        let order: [ServiceStatusLevel] = [
            .majorOutage, .partialOutage, .degradedPerformance,
            .maintenance, .unknown, .operational,
        ]
        return order.compactMap { level in
            guard let seconds = durations[level], seconds >= 60 else { return nil }
            let parts = DurationParts.hoursMinutes(seconds)
            let duration = L10n.localizedString(
                "service_status_duration_fmt",
                parts.hours,
                parts.minutes
            )
            return "\(L10n.localizedString(ServiceStatusPresentation.levelKey(for: level))) \(duration)"
        }.joined(separator: ", ")
    }
}

private struct IncidentDetailView: View {
    let incident: ServiceIncident
    let vendorId: VendorId

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: ServiceStatusPresentation.symbol(for: incident.level))
                    .foregroundStyle(incident.level.statusColor)
                Text(incident.title)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
            }
            Text("\(phaseText) · \(durationText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !incident.affectedComponents.isEmpty {
                Text(L10n.localizedString(
                    "service_status_components_fmt",
                    incident.affectedComponents.joined(separator: ", ")
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let message = incident.message, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link = ServiceStatusPresentation.safeURL(incident.sourceURL, for: vendorId) {
                Link(destination: link) {
                    Label(L10n.localizedString("service_status_open_incident"),
                          systemImage: "arrow.up.right.square")
                }
                .font(.caption2)
            }
        }
    }

    private var phaseText: String {
        L10n.localizedString(ServiceStatusPresentation.phaseKey(for: incident.phase))
    }

    private var durationText: String {
        let end = incident.resolvedAt ?? .now
        let parts = DurationParts.hoursMinutes(end.timeIntervalSince(incident.startedAt))
        return L10n.localizedString(
            "service_status_duration_fmt",
            parts.hours,
            parts.minutes
        )
    }
}
