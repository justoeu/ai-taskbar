import Foundation
import AiTaskbarCore

public enum ServiceStatusTone: String, Sendable, Equatable {
    case positive
    case maintenance
    case warning
    case danger
    case secondary
}

public struct ServiceStatusTimelineSegment: Sendable, Equatable {
    public let level: ServiceStatusLevel
    public let startFraction: Double
    public let endFraction: Double

    public init(level: ServiceStatusLevel, startFraction: Double, endFraction: Double) {
        self.level = level
        self.startFraction = startFraction
        self.endFraction = endFraction
    }
}

/// Pure, UI-framework-free mapping for status labels, symbols, safe links,
/// empty-state semantics, and six-hour timeline geometry.
public enum ServiceStatusPresentation {
    public static let headerSymbol = "waveform.path.ecg"

    public static let localizationKeys = [
        "service_status_help", "service_status_ax_label", "service_status_ax_value_fmt",
        "service_status_ax_hint", "service_status_title", "service_status_last_six_hours",
        "service_status_minus_six_hours", "service_status_now", "service_status_refresh",
        "service_status_close", "service_status_loading", "service_status_never_updated",
        "service_status_no_automatic_sources",
        "service_status_updated_fmt", "service_status_stale_fmt", "service_status_cold_error",
        "service_status_retry", "service_status_empty_full",
        "service_status_empty_incidents_only", "service_status_empty_link_only",
        "service_status_level_operational", "service_status_level_maintenance",
        "service_status_level_degraded", "service_status_level_partial_outage",
        "service_status_level_major_outage", "service_status_level_unknown",
        "service_status_level_no_active_incidents",
        "service_status_coverage_full", "service_status_coverage_incidents_only",
        "service_status_coverage_link_only", "service_status_phase_investigating",
        "service_status_phase_identified", "service_status_phase_monitoring",
        "service_status_phase_resolved", "service_status_phase_scheduled",
        "service_status_phase_in_progress", "service_status_phase_completed",
        "service_status_phase_unknown", "service_status_expand", "service_status_collapse",
        "service_status_components_fmt", "service_status_duration_fmt",
        "service_status_open_incident", "service_status_open_page",
        "service_status_timeline_ax_fmt", "service_status_legend",
        "service_status_scope_note",
    ]

    public static func symbol(for level: ServiceStatusLevel) -> String {
        switch level {
        case .operational: return "checkmark.circle.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .degradedPerformance: return "exclamationmark.triangle.fill"
        case .partialOutage, .majorOutage: return "xmark.octagon.fill"
        case .unknown: return "circle.dashed"
        }
    }

    public static func tone(for level: ServiceStatusLevel) -> ServiceStatusTone {
        switch level {
        case .operational: return .positive
        case .maintenance: return .maintenance
        case .degradedPerformance: return .warning
        case .partialOutage, .majorOutage: return .danger
        case .unknown: return .secondary
        }
    }

    public static func levelKey(for level: ServiceStatusLevel) -> String {
        switch level {
        case .operational: return "service_status_level_operational"
        case .maintenance: return "service_status_level_maintenance"
        case .degradedPerformance: return "service_status_level_degraded"
        case .partialOutage: return "service_status_level_partial_outage"
        case .majorOutage: return "service_status_level_major_outage"
        case .unknown: return "service_status_level_unknown"
        }
    }

    public static func displayLevelKey(
        for status: VendorServiceStatus,
        hasObservation: Bool
    ) -> String {
        if hasObservation,
           status.coverage == .incidentsOnly,
           status.level == .unknown {
            return "service_status_level_no_active_incidents"
        }
        return levelKey(for: status.level)
    }

    public static func coverageKey(for coverage: ServiceStatusCoverage) -> String {
        switch coverage {
        case .full: return "service_status_coverage_full"
        case .incidentsOnly: return "service_status_coverage_incidents_only"
        case .linkOnly: return "service_status_coverage_link_only"
        }
    }

    public static func phaseKey(for phase: ServiceIncidentPhase) -> String {
        switch phase {
        case .investigating: return "service_status_phase_investigating"
        case .identified: return "service_status_phase_identified"
        case .monitoring: return "service_status_phase_monitoring"
        case .resolved: return "service_status_phase_resolved"
        case .scheduled: return "service_status_phase_scheduled"
        case .inProgress: return "service_status_phase_in_progress"
        case .completed: return "service_status_phase_completed"
        case .unknown: return "service_status_phase_unknown"
        }
    }

    public static func emptyStateKey(for coverage: ServiceStatusCoverage) -> String {
        switch coverage {
        case .full: return "service_status_empty_full"
        case .incidentsOnly: return "service_status_empty_incidents_only"
        case .linkOnly: return "service_status_empty_link_only"
        }
    }

    public static func expectedCoverage(for vendorId: VendorId) -> ServiceStatusCoverage {
        switch vendorId {
        case .anthropic, .openai, .kimi, .deepseek: return .full
        case .openrouter, .xai: return .incidentsOnly
        case .gemini, .zai: return .linkOnly
        }
    }

    /// Defense in depth for links received from public feeds. Only HTTPS on
    /// the vendor's exact fixed status-page host is exposed to NSWorkspace.
    public static func safeURL(_ url: URL?, for vendorId: VendorId) -> URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              let expectedHost = vendorId.statusPageURL?.host?.lowercased(),
              url.host?.lowercased() == expectedHost
        else { return nil }
        return url
    }

    public static func placeholder(for vendorId: VendorId) -> VendorServiceStatus {
        VendorServiceStatus(
            vendorId: vendorId,
            level: .unknown,
            coverage: expectedCoverage(for: vendorId),
            summary: "",
            sourceURL: vendorId.statusPageURL,
            sourceUpdatedAt: nil,
            incidents: []
        )
    }

    /// Base track plus clipped incident overlays. A full source may claim an
    /// operational background; incident-only and link-only tracks remain
    /// unknown unless an incident explicitly occupies a range.
    public static func timelineSegments(
        for status: VendorServiceStatus,
        now: Date
    ) -> [ServiceStatusTimelineSegment] {
        let cutoff = ServiceStatusWindow.cutoff(for: now)
        return sweptSegments(for: status, now: now).map {
            ServiceStatusTimelineSegment(
                level: $0.level,
                startFraction: fraction($0.start, cutoff: cutoff, now: now),
                endFraction: fraction($0.end, cutoff: cutoff, now: now)
            )
        }
    }

    /// Computes non-overlapping duration totals using the worst active level
    /// in each interval, so overlapping incidents never double-count time.
    public static func durationByLevel(
        for status: VendorServiceStatus,
        now: Date
    ) -> [ServiceStatusLevel: TimeInterval] {
        var durations: [ServiceStatusLevel: TimeInterval] = [:]
        for segment in sweptSegments(for: status, now: now) {
            durations[segment.level, default: 0] += segment.end.timeIntervalSince(segment.start)
        }
        return durations
    }

    private struct DatedSegment {
        let level: ServiceStatusLevel
        let start: Date
        var end: Date
    }

    private static func sweptSegments(
        for status: VendorServiceStatus,
        now: Date
    ) -> [DatedSegment] {
        let cutoff = ServiceStatusWindow.cutoff(for: now)
        let ranges = ServiceStatusWindow.recentIncidents(status.incidents, now: now)
            .compactMap { incident -> (ServiceStatusLevel, ClosedRange<Date>)? in
                guard let range = ServiceStatusWindow.clippedRange(for: incident, now: now) else {
                    return nil
                }
                return (incident.level, range)
            }
        let boundaries = Set([cutoff, now] + ranges.flatMap {
            [$0.1.lowerBound, $0.1.upperBound]
        }).sorted()
        let baseline: ServiceStatusLevel = status.coverage == .full && status.level != .unknown
            ? .operational
            : .unknown
        var result: [DatedSegment] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let active = ranges.compactMap { level, range in
                range.contains(midpoint) ? level : nil
            }
            let level = active.isEmpty
                ? baseline
                : ServiceStatusWindow.worstLevel(in: active)
            if result.last?.level == level {
                result[result.count - 1].end = end
            } else {
                result.append(DatedSegment(level: level, start: start, end: end))
            }
        }
        return result
    }

    private static func fraction(_ date: Date, cutoff: Date, now: Date) -> Double {
        guard now > cutoff else { return 0 }
        return min(1, max(0, date.timeIntervalSince(cutoff) / now.timeIntervalSince(cutoff)))
    }
}
