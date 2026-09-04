import SwiftUI
import AiTaskbarCore

public struct StatusPanelView: View {
    @EnvironmentObject private var store: ServiceStatusStore
    public let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.rows) { row in
                        StatusVendorRowView(row: row)
                            .environmentObject(store)
                    }
                }
                .padding(12)
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
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ServiceStatusPresentation.symbol(for: store.overallLevel))
                .font(.title2)
                .foregroundStyle(store.overallLevel.statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                L10n.text("service_status_title")
                    .font(.headline)
                L10n.text("service_status_last_six_hours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(headerFreshness)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                store.refreshAll(forceRefresh: true)
            } label: {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isLoading)
            .help(L10n.localizedString("service_status_refresh"))
            .accessibilityLabel(L10n.localizedString("service_status_refresh"))
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help(L10n.localizedString("service_status_close"))
            .accessibilityLabel(L10n.localizedString("service_status_close"))
        }
        .padding(12)
    }

    private var headerFreshness: String {
        if store.isLoading { return L10n.localizedString("service_status_loading") }
        guard let completed = store.lastCompletedRefreshAt else {
            return L10n.localizedString("service_status_never_updated")
        }
        return L10n.localizedString(
            "service_status_updated_fmt",
            Self.timeFormatter.string(from: completed)
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            L10n.text("service_status_legend")
                .font(.caption)
                .foregroundStyle(.secondary)
            L10n.text("service_status_scope_note")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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
    @State private var isExpanded: Bool

    init(row: ServiceStatusStore.Row) {
        self.row = row
        let level = row.state.status?.level ?? .unknown
        _isExpanded = State(initialValue: level != .operational)
    }

    private var status: VendorServiceStatus {
        row.state.status ?? ServiceStatusPresentation.placeholder(for: row.vendorId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: ServiceStatusPresentation.symbol(for: status.level))
                        .foregroundStyle(status.level.statusColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.vendorId.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(L10n.localizedString(
                            ServiceStatusPresentation.levelKey(for: status.level)
                        ))
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
            .accessibilityValue(L10n.localizedString(
                ServiceStatusPresentation.levelKey(for: status.level)
            ))
            .accessibilityHint(L10n.localizedString(
                isExpanded ? "service_status_collapse" : "service_status_expand"
            ))

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
        case .ok(let outcome) where outcome.isStale:
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
                    ServiceStatusPresentation.emptyStateKey(for: status.coverage)
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
            let totalMinutes = Int(seconds / 60)
            let duration = L10n.localizedString(
                "service_status_duration_fmt",
                totalMinutes / 60,
                totalMinutes % 60
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
        let totalMinutes = max(0, Int(end.timeIntervalSince(incident.startedAt) / 60))
        return L10n.localizedString(
            "service_status_duration_fmt",
            totalMinutes / 60,
            totalMinutes % 60
        )
    }
}
