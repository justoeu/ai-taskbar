import Foundation

public enum ServiceStatusLevel: String, Codable, Sendable, Equatable {
    case operational
    case maintenance
    case degradedPerformance
    case partialOutage
    case majorOutage
    case unknown
}

public enum ServiceStatusCoverage: String, Codable, Sendable, Equatable {
    case full
    case incidentsOnly
    case linkOnly
}

public enum ServiceIncidentPhase: String, Codable, Sendable, Equatable {
    case investigating
    case identified
    case monitoring
    case resolved
    case scheduled
    case inProgress
    case completed
    case unknown
}

public struct ServiceIncident: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let level: ServiceStatusLevel
    public let phase: ServiceIncidentPhase
    public let startedAt: Date
    public let updatedAt: Date
    public let resolvedAt: Date?
    public let affectedComponents: [String]
    public let message: String?
    public let sourceURL: URL?

    public init(
        id: String,
        title: String,
        level: ServiceStatusLevel,
        phase: ServiceIncidentPhase,
        startedAt: Date,
        updatedAt: Date,
        resolvedAt: Date?,
        affectedComponents: [String],
        message: String?,
        sourceURL: URL?
    ) {
        self.id = id
        self.title = title
        self.level = level
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
        self.affectedComponents = affectedComponents
        self.message = message
        self.sourceURL = sourceURL
    }
}

public struct VendorServiceStatus: Codable, Sendable, Equatable {
    public let vendorId: VendorId
    public let level: ServiceStatusLevel
    public let coverage: ServiceStatusCoverage
    public let summary: String
    public let sourceURL: URL?
    public let sourceUpdatedAt: Date?
    public let incidents: [ServiceIncident]

    public init(
        vendorId: VendorId,
        level: ServiceStatusLevel,
        coverage: ServiceStatusCoverage,
        summary: String,
        sourceURL: URL?,
        sourceUpdatedAt: Date?,
        incidents: [ServiceIncident]
    ) {
        self.vendorId = vendorId
        self.level = level
        self.coverage = coverage
        self.summary = summary
        self.sourceURL = sourceURL
        self.sourceUpdatedAt = sourceUpdatedAt
        self.incidents = incidents
    }
}

/// Pure helpers for the closed, moving `[now - 6h, now]` status window.
public enum ServiceStatusWindow {
    public static let duration: TimeInterval = 6 * 60 * 60

    public static func cutoff(for now: Date) -> Date {
        now.addingTimeInterval(-duration)
    }

    public static func intersects(_ incident: ServiceIncident, now: Date) -> Bool {
        incident.startedAt <= now
            && (incident.resolvedAt ?? now) >= cutoff(for: now)
    }

    /// Returns the incident interval clipped for display without changing the
    /// source timestamps. Incidents outside the window return `nil`.
    public static func clippedRange(
        for incident: ServiceIncident,
        now: Date
    ) -> ClosedRange<Date>? {
        guard intersects(incident, now: now) else { return nil }
        let lowerBound = max(incident.startedAt, cutoff(for: now))
        let upperBound = min(incident.resolvedAt ?? now, now)
        guard lowerBound <= upperBound else { return nil }
        return lowerBound ... upperBound
    }

    /// Filters to the status window and orders newest update first, using the
    /// stable incident identifier as the deterministic tie-breaker.
    public static func recentIncidents(
        _ incidents: [ServiceIncident],
        now: Date
    ) -> [ServiceIncident] {
        incidents
            .filter { intersects($0, now: now) }
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.id < $1.id
            }
    }

    /// Returns the worst known condition. Unknown blocks an all-green result,
    /// but any known non-operational condition takes precedence over unknown.
    public static func worstLevel(in levels: [ServiceStatusLevel]) -> ServiceStatusLevel {
        let severity: [ServiceStatusLevel: Int] = [
            .maintenance: 1,
            .degradedPerformance: 2,
            .partialOutage: 3,
            .majorOutage: 4,
        ]
        let worstKnown = levels
            .filter { $0 != .operational && $0 != .unknown }
            .max { severity[$0, default: 0] < severity[$1, default: 0] }
        if let worstKnown { return worstKnown }
        if levels.isEmpty || levels.contains(.unknown) { return .unknown }
        return .operational
    }

    /// Coverage without an explicit global state cannot make the aggregate
    /// green, even if an adapter accidentally labels it operational.
    public static func overallLevel(
        for statuses: [VendorServiceStatus]
    ) -> ServiceStatusLevel {
        worstLevel(in: statuses.map { status in
            if status.coverage != .full && status.level == .operational {
                return .unknown
            }
            return status.level
        })
    }
}

public extension VendorId {
    /// Fixed official service-status pages. No user-controlled URL enters
    /// this mapping; vendors without a verified page intentionally return nil.
    var statusPageURL: URL? {
        switch self {
        case .anthropic:  return URL(string: "https://status.claude.com")
        case .openai:     return URL(string: "https://status.openai.com")
        case .zai:        return nil
        case .openrouter: return URL(string: "https://status.openrouter.ai")
        case .kimi:       return URL(string: "https://status.moonshot.cn")
        case .gemini:     return URL(string: "https://aistudio.google.com/status")
        case .deepseek:   return URL(string: "https://status.deepseek.com")
        case .xai:        return URL(string: "https://status.x.ai")
        }
    }
}
