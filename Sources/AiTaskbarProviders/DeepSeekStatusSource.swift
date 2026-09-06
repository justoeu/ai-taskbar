import Foundation
import AiTaskbarCore

/// Experimental adapter for DeepSeek's public FlashDuty JSON status page.
/// The upstream contract is undocumented, so schema drift deliberately fails
/// into the shared stale-cache lifecycle instead of guessing from HTML.
public struct DeepSeekStatusSource: ServiceStatusSource, Sendable {
    public static let maximumResponseBytes = 2 * 1024 * 1024
    public static let maximumItems = 200

    private static let baseURL = URL(string: "https://status.deepseek.com")!
    private static let pageID = "6410630422455"

    public var vendorId: VendorId { .deepseek }

    public init() {}

    public func fetchPayload(
        http: HTTPClient,
        now: Date
    ) async throws -> DeepSeekStatusPayload {
        try Task.checkCancellation()
        let lower = Int64(ServiceStatusWindow.cutoff(for: now).timeIntervalSince1970)
        let upper = Int64(now.timeIntervalSince1970)

        async let active: DeepSeekStatusEnvelope<DeepSeekActiveStatus> = fetchJSON(
            url: try endpoint("summary/active"),
            as: DeepSeekStatusEnvelope<DeepSeekActiveStatus>.self,
            http: http
        )
        async let structure: DeepSeekStatusEnvelope<DeepSeekStatusStructure> = fetchJSON(
            url: try endpoint(
                "summary/structure",
                queryItems: [
                    URLQueryItem(name: "start_at_from_seconds", value: String(lower)),
                    URLQueryItem(name: "start_at_to_seconds", value: String(upper)),
                ]
            ),
            as: DeepSeekStatusEnvelope<DeepSeekStatusStructure>.self,
            http: http
        )
        async let changes: DeepSeekStatusEnvelope<DeepSeekChangeList> = fetchJSON(
            url: try endpoint(
                "change/list",
                queryItems: [
                    URLQueryItem(name: "start_at_seconds", value: String(lower)),
                    URLQueryItem(name: "end_at_seconds", value: String(upper)),
                ]
            ),
            as: DeepSeekStatusEnvelope<DeepSeekChangeList>.self,
            http: http
        )

        let payload = try await DeepSeekStatusPayload(
            active: active,
            structure: structure,
            changes: changes
        )
        try Task.checkCancellation()
        try validate(payload)
        try Task.checkCancellation()
        return payload
    }

    public func makeStatus(
        from payload: DeepSeekStatusPayload,
        now: Date
    ) throws -> VendorServiceStatus {
        try validate(payload)

        let activeChanges = payload.active.data.activeChanges
        let currentLevel: ServiceStatusLevel
        if activeChanges.isEmpty {
            currentLevel = .operational
        } else {
            currentLevel = ServiceStatusWindow.worstLevel(
                in: activeChanges.map(currentLevel(for:))
            )
        }

        var byID: [String: ServiceIncident] = [:]
        for change in payload.changes.data.items + activeChanges {
            let incident = makeIncident(change)
            if let existing = byID[incident.id], existing.updatedAt >= incident.updatedAt {
                continue
            }
            byID[incident.id] = incident
        }

        let newestActive = activeChanges.max {
            updateDate(for: $0) < updateDate(for: $1)
        }
        let sourceUpdatedAt = newestActive.map(updateDate(for:))
        let summary: String
        if currentLevel == .operational {
            summary = ""
        } else {
            summary = clean(newestActive?.title, limit: 500) ?? "Service status unavailable"
        }

        return VendorServiceStatus(
            vendorId: .deepseek,
            level: currentLevel,
            coverage: .full,
            summary: summary,
            sourceURL: Self.baseURL,
            sourceUpdatedAt: sourceUpdatedAt,
            incidents: ServiceStatusWindow.recentIncidents(Array(byID.values), now: now)
        )
    }

    private func fetchJSON<Value: Decodable & Sendable>(
        url: URL,
        as type: Value.Type,
        http: HTTPClient
    ) async throws -> Value {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await http.sendBounded(
            request,
            maximumResponseBytes: Self.maximumResponseBytes
        )
        try Task.checkCancellation()
        try validateResponse(data: data, response: response, expectedURL: url)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data.prefix(1_024), encoding: .utf8) ?? ""
            throw AppError.http(status: response.statusCode, body: body)
        }
        do {
            return try SharedCoders.decoder.decode(type, from: data)
        } catch {
            throw AppError.schema("DeepSeek status decode: \(error)")
        }
    }

    private func endpoint(
        _ suffix: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        let raw = Self.baseURL
            .appendingPathComponent("api/status-page")
            .appendingPathComponent(Self.pageID)
            .appendingPathComponent(suffix)
        guard var components = URLComponents(url: raw, resolvingAgainstBaseURL: false) else {
            throw AppError.schema("invalid DeepSeek status endpoint")
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "status.deepseek.com"
        else {
            throw AppError.schema("invalid DeepSeek status HTTPS host")
        }
        return url
    }

    private func validateResponse(
        data: Data,
        response: HTTPURLResponse,
        expectedURL: URL
    ) throws {
        guard data.count <= Self.maximumResponseBytes else {
            throw AppError.schema("DeepSeek status response exceeds 2 MiB")
        }
        guard response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == expectedURL.host?.lowercased(),
              response.url?.user == nil,
              response.url?.password == nil,
              response.url?.port == nil
        else {
            throw AppError.transport("DeepSeek status redirect left allowed host")
        }
    }

    private func validate(_ payload: DeepSeekStatusPayload) throws {
        let active = payload.active.data
        guard active.page.pageID == Int64(Self.pageID),
              active.page.customDomain.lowercased() == "status.deepseek.com"
        else {
            throw AppError.schema("DeepSeek status page identity changed")
        }
        guard active.page.components.count <= Self.maximumItems,
              active.page.sections.count <= Self.maximumItems,
              active.activeChanges.count <= Self.maximumItems,
              payload.changes.data.items.count <= Self.maximumItems,
              payload.structure.data.sectionImpacts.count <= Self.maximumItems,
              payload.structure.data.sectionUptimes.count <= Self.maximumItems,
              payload.structure.data.componentImpacts.count <= Self.maximumItems,
              payload.structure.data.componentUptimes.count <= Self.maximumItems,
              payload.structure.data.linkedChanges.count <= Self.maximumItems
        else {
            throw AppError.schema("DeepSeek status item limit exceeded")
        }
        for change in payload.changes.data.items + active.activeChanges {
            guard change.pageID == active.page.pageID,
                  change.startAtSeconds > 0,
                  change.affectedComponents.count <= Self.maximumItems,
                  change.updates.count <= Self.maximumItems,
                  change.updates.allSatisfy({
                      $0.atSeconds > 0 && $0.componentChanges.count <= Self.maximumItems
                  })
            else {
                throw AppError.schema("DeepSeek status change schema invalid")
            }
        }
    }

    private func currentLevel(for change: DeepSeekStatusChange) -> ServiceStatusLevel {
        if change.type.lowercased() == "maintenance" { return .maintenance }
        let latest = change.updates.max { $0.atSeconds < $1.atSeconds }
        let tokens = change.affectedComponents.compactMap(\.status)
            + (latest?.componentChanges.map(\.status) ?? [])
        let level = ServiceStatusWindow.worstLevel(in: tokens.map(level(for:)))
        if level == .operational || level == .unknown {
            switch phase(for: change.status) {
            case .investigating, .identified, .monitoring:
                return .degradedPerformance
            default:
                return level
            }
        }
        return level
    }

    private func makeIncident(_ change: DeepSeekStatusChange) -> ServiceIncident {
        let latest = change.updates.max { $0.atSeconds < $1.atSeconds }
        let allTokens = change.affectedComponents.compactMap(\.status)
            + change.updates.flatMap { $0.componentChanges.map(\.status) }
        var incidentLevel: ServiceStatusLevel
        if change.type.lowercased() == "maintenance" {
            incidentLevel = .maintenance
        } else {
            incidentLevel = ServiceStatusWindow.worstLevel(in: allTokens.map(level(for:)))
            if incidentLevel == .operational && change.status.lowercased() != "resolved" {
                incidentLevel = .degradedPerformance
            }
        }

        var componentNames: [String] = []
        var seen = Set<String>()
        for name in change.affectedComponents.map(\.name)
            + change.updates.flatMap({ $0.componentChanges.map(\.componentName) }) {
            guard let bounded = clean(name, limit: 200), seen.insert(bounded).inserted else {
                continue
            }
            componentNames.append(bounded)
            if componentNames.count == 50 { break }
        }

        let resolved: Date?
        switch phase(for: change.status) {
        case .resolved, .completed:
            resolved = change.closeAtSeconds.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }
                ?? latest.map { Date(timeIntervalSince1970: TimeInterval($0.atSeconds)) }
        default:
            resolved = nil
        }

        return ServiceIncident(
            id: String(change.changeID),
            title: clean(change.title, limit: 300) ?? "Untitled incident",
            level: incidentLevel,
            phase: phase(for: change.status),
            startedAt: Date(timeIntervalSince1970: TimeInterval(change.startAtSeconds)),
            updatedAt: updateDate(for: change),
            resolvedAt: resolved,
            affectedComponents: componentNames,
            message: clean(latest?.description ?? change.description, limit: 1_000),
            sourceURL: nil
        )
    }

    private func updateDate(for change: DeepSeekStatusChange) -> Date {
        let seconds = change.updates.map(\.atSeconds).max()
            ?? change.closeAtSeconds
            ?? change.startAtSeconds
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private func level(for token: String) -> ServiceStatusLevel {
        switch token.lowercased() {
        case "operational", "available", "none": return .operational
        case "maintenance", "under_maintenance": return .maintenance
        case "degraded", "degraded_performance", "minor": return .degradedPerformance
        case "partial_outage", "major": return .partialOutage
        case "full_outage", "major_outage", "critical": return .majorOutage
        default: return .unknown
        }
    }

    private func phase(for token: String) -> ServiceIncidentPhase {
        switch token.lowercased() {
        case "investigating": return .investigating
        case "identified": return .identified
        case "monitoring": return .monitoring
        case "resolved": return .resolved
        case "scheduled": return .scheduled
        case "in_progress": return .inProgress
        case "completed": return .completed
        default: return .unknown
        }
    }

    private func clean(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let scalars = raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
        let value = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(limit))
    }
}
