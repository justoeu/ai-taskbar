import Foundation
import AiTaskbarCore

public struct StatuspageComponentDescriptor: Sendable, Equatable {
    public let id: String?
    public let name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }
}

public struct StatuspageDescriptor: Sendable, Equatable {
    public let vendorId: VendorId
    public let baseURL: URL
    public let components: [StatuspageComponentDescriptor]

    public init(
        vendorId: VendorId,
        baseURL: URL,
        components: [StatuspageComponentDescriptor]
    ) {
        self.vendorId = vendorId
        self.baseURL = baseURL
        self.components = components
    }

    public static let anthropic = StatuspageDescriptor(
        vendorId: .anthropic,
        baseURL: URL(string: "https://status.claude.com")!,
        components: [
            StatuspageComponentDescriptor(id: "k8w3r06qmzrp", name: "Claude API"),
            StatuspageComponentDescriptor(id: "yyzkbfz2thpt", name: "Claude Code"),
        ]
    )

    public static let openAI = StatuspageDescriptor(
        vendorId: .openai,
        baseURL: URL(string: "https://status.openai.com")!,
        components: [
            StatuspageComponentDescriptor(id: "01JVCV8YSWZFRSM1G5CVP253SK", name: "Codex Web"),
            StatuspageComponentDescriptor(id: "01KMKFAMWKQ81YWSE1Z18R6VHR", name: "Codex in ChatGPT Desktop"),
            StatuspageComponentDescriptor(id: "01KMP3KP5MGE23B80K1EK4S8PV", name: "Codex API"),
            StatuspageComponentDescriptor(id: nil, name: "Codex CLI"),
            StatuspageComponentDescriptor(id: "01KMP3KP5M8X0EBTVW6KN327EE", name: "VS Code extension"),
        ]
    )

    public static let kimi = StatuspageDescriptor(
        vendorId: .kimi,
        baseURL: URL(string: "https://status.moonshot.cn")!,
        components: [
            StatuspageComponentDescriptor(id: "8psr5dfdld0s", name: "Open API"),
        ]
    )
}

public struct StatuspageSource: ServiceStatusSource, Sendable {
    public static let maximumResponseBytes = 2 * 1024 * 1024
    public static let maximumItems = 200

    public let descriptor: StatuspageDescriptor
    public var vendorId: VendorId { descriptor.vendorId }

    public init(descriptor: StatuspageDescriptor) {
        self.descriptor = descriptor
    }

    public func fetchPayload(
        http: HTTPClient,
        now: Date
    ) async throws -> StatuspageCachedPayload {
        _ = now
        try Task.checkCancellation()
        try validateDescriptor()

        async let summary: StatuspageSummary = fetchJSON(
            path: "summary.json",
            as: StatuspageSummary.self,
            http: http
        )
        async let incidents: StatuspageIncidentList = fetchJSON(
            path: "incidents.json",
            as: StatuspageIncidentList.self,
            http: http
        )
        async let maintenances: StatuspageMaintenanceList = fetchMaintenances(http: http)

        let payload = try await StatuspageCachedPayload(
            summary: summary,
            incidents: incidents,
            scheduledMaintenances: maintenances
        )
        try validate(payload)
        try Task.checkCancellation()
        return payload
    }

    public func makeStatus(
        from payload: StatuspageCachedPayload,
        now: Date
    ) throws -> VendorServiceStatus {
        try validate(payload)
        let summaryLevel = level(for: payload.summary.status.indicator)
        let componentLevels = payload.summary.components.compactMap { component in
            matchesDescriptor(id: component.id, name: component.name)
                ? level(for: component.status)
                : nil
        }
        let currentLevel = ServiceStatusWindow.worstLevel(
            in: [summaryLevel] + componentLevels
        )

        let ordinary = payload.incidents.incidents + payload.summary.incidents
        let maintenance = payload.scheduledMaintenances.scheduledMaintenances
            + payload.summary.scheduledMaintenances
        var mapped: [ServiceIncident] = []
        mapped.reserveCapacity(ordinary.count + maintenance.count)
        for incident in ordinary where isRelevant(incident) {
            mapped.append(try makeIncident(incident, isMaintenance: false))
        }
        for incident in maintenance where isRelevant(incident) {
            mapped.append(try makeIncident(incident, isMaintenance: true))
        }

        var uniqueByID: [String: ServiceIncident] = [:]
        for incident in mapped {
            if let existing = uniqueByID[incident.id], existing.updatedAt >= incident.updatedAt {
                continue
            }
            uniqueByID[incident.id] = incident
        }

        let sourceUpdatedAt: Date?
        if let raw = payload.summary.page.updatedAt {
            guard let parsed = ISO8601Parsing.parse(raw) else {
                throw AppError.schema("statuspage invalid page.updated_at")
            }
            sourceUpdatedAt = parsed
        } else {
            sourceUpdatedAt = nil
        }

        return VendorServiceStatus(
            vendorId: descriptor.vendorId,
            level: currentLevel,
            coverage: .full,
            summary: clean(payload.summary.status.description, limit: 500) ?? "",
            sourceURL: descriptor.baseURL,
            sourceUpdatedAt: sourceUpdatedAt,
            incidents: ServiceStatusWindow.recentIncidents(
                Array(uniqueByID.values),
                now: now
            )
        )
    }

    private func fetchJSON<Value: Decodable & Sendable>(
        path: String,
        as type: Value.Type,
        http: HTTPClient
    ) async throws -> Value {
        try Task.checkCancellation()
        let requestURL = endpoint(path)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        let (data, response) = try await http.sendBounded(
            request,
            maximumResponseBytes: Self.maximumResponseBytes
        )
        try Task.checkCancellation()
        try validateResponse(data: data, response: response, expectedURL: requestURL)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data.prefix(1024), encoding: .utf8) ?? ""
            throw AppError.http(status: response.statusCode, body: body)
        }
        do {
            return try SharedCoders.decoder.decode(type, from: data)
        } catch {
            throw AppError.schema("statuspage \(path) decode: \(error)")
        }
    }

    private func fetchMaintenances(http: HTTPClient) async throws -> StatuspageMaintenanceList {
        try Task.checkCancellation()
        let requestURL = endpoint("scheduled-maintenances.json")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        let (data, response) = try await http.sendBounded(
            request,
            maximumResponseBytes: Self.maximumResponseBytes
        )
        try Task.checkCancellation()
        try validateResponse(data: data, response: response, expectedURL: requestURL)
        if response.statusCode == 404 {
            return StatuspageMaintenanceList(scheduledMaintenances: [])
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data.prefix(1024), encoding: .utf8) ?? ""
            throw AppError.http(status: response.statusCode, body: body)
        }
        do {
            return try SharedCoders.decoder.decode(StatuspageMaintenanceList.self, from: data)
        } catch {
            throw AppError.schema("statuspage scheduled-maintenances.json decode: \(error)")
        }
    }

    private func validateDescriptor() throws {
        guard descriptor.baseURL.scheme?.lowercased() == "https",
              descriptor.baseURL.host?.lowercased()
                == descriptor.vendorId.statusPageURL?.host?.lowercased(),
              descriptor.baseURL.user == nil,
              descriptor.baseURL.password == nil,
              descriptor.baseURL.port == nil,
              descriptor.baseURL.path.isEmpty || descriptor.baseURL.path == "/"
        else {
            throw AppError.schema("invalid statuspage HTTPS host for \(descriptor.vendorId.rawValue)")
        }
    }

    private func validateResponse(
        data: Data,
        response: HTTPURLResponse,
        expectedURL: URL
    ) throws {
        guard data.count <= Self.maximumResponseBytes else {
            throw AppError.schema("statuspage response exceeds 2 MiB")
        }
        guard response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == expectedURL.host?.lowercased(),
              response.url?.user == nil,
              response.url?.password == nil,
              response.url?.port == nil
        else {
            throw AppError.transport("statuspage redirect left allowed host")
        }
    }

    private func validate(_ payload: StatuspageCachedPayload) throws {
        let incidents = payload.summary.incidents
            + payload.summary.scheduledMaintenances
            + payload.incidents.incidents
            + payload.scheduledMaintenances.scheduledMaintenances
        guard payload.summary.components.count <= Self.maximumItems,
              payload.summary.incidents.count <= Self.maximumItems,
              payload.summary.scheduledMaintenances.count <= Self.maximumItems,
              payload.incidents.incidents.count <= Self.maximumItems,
              payload.scheduledMaintenances.scheduledMaintenances.count <= Self.maximumItems,
              incidents.allSatisfy({ incident in
                  (incident.components?.count ?? 0) <= Self.maximumItems
                      && incident.incidentUpdates.count <= Self.maximumItems
                      && incident.incidentUpdates.allSatisfy {
                          ($0.affectedComponents?.count ?? 0) <= Self.maximumItems
                      }
              })
        else {
            throw AppError.schema("statuspage item limit exceeded")
        }
    }

    private func endpoint(_ file: String) -> URL {
        descriptor.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v2")
            .appendingPathComponent(file)
    }

    private func isRelevant(_ incident: StatuspageIncident) -> Bool {
        guard let components = incident.components, !components.isEmpty else {
            return true
        }
        return components.contains {
            matchesDescriptor(id: $0.id, name: $0.name)
        }
    }

    private func matchesDescriptor(id: String, name: String) -> Bool {
        descriptor.components.contains { component in
            component.id == id || component.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func makeIncident(
        _ incident: StatuspageIncident,
        isMaintenance: Bool
    ) throws -> ServiceIncident {
        let startRaw = incident.scheduledFor ?? incident.startedAt ?? incident.createdAt
        guard let startedAt = ISO8601Parsing.parse(startRaw),
              let updatedAt = ISO8601Parsing.parse(incident.updatedAt)
        else {
            throw AppError.schema("statuspage incident \(incident.id) has invalid timestamps")
        }

        let resolvedRaw: String?
        if incident.status == "completed" {
            resolvedRaw = incident.resolvedAt ?? incident.scheduledUntil
        } else {
            resolvedRaw = incident.resolvedAt
        }
        let resolvedAt: Date?
        if let resolvedRaw {
            guard let parsed = ISO8601Parsing.parse(resolvedRaw) else {
                throw AppError.schema("statuspage incident \(incident.id) has invalid resolved_at")
            }
            resolvedAt = parsed
        } else {
            resolvedAt = nil
        }

        let latestUpdate = incident.incidentUpdates.max { lhs, rhs in
            updateDate(lhs) < updateDate(rhs)
        }
        let affectedComponents = componentNames(
            incident: incident,
            latestUpdate: latestUpdate
        )

        return ServiceIncident(
            id: clean(incident.id, limit: 200) ?? incident.id,
            title: clean(incident.name, limit: 300) ?? incident.name,
            level: isMaintenance ? .maintenance : level(for: incident.impact),
            phase: phase(for: incident.status),
            startedAt: startedAt,
            updatedAt: updatedAt,
            resolvedAt: resolvedAt,
            affectedComponents: affectedComponents,
            message: clean(latestUpdate?.body, limit: 1_000),
            sourceURL: safeSourceURL(incident.shortlink)
        )
    }

    private func componentNames(
        incident: StatuspageIncident,
        latestUpdate: StatuspageIncidentUpdate?
    ) -> [String] {
        let componentIDs = Set((incident.components ?? []).map(\.id))
            .union((latestUpdate?.affectedComponents ?? []).map(\.code))
        let wireNames = Set((incident.components ?? []).map(\.name))
            .union((latestUpdate?.affectedComponents ?? []).map(\.name))

        return descriptor.components.compactMap { component in
            let matchesID = component.id.map(componentIDs.contains) ?? false
            let matchesName = wireNames.contains {
                $0.caseInsensitiveCompare(component.name) == .orderedSame
            }
            return matchesID || matchesName ? component.name : nil
        }
    }

    private func safeSourceURL(_ raw: String?) -> URL? {
        guard let raw,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == descriptor.baseURL.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.port == nil
        else { return nil }
        return url
    }

    private func updateDate(_ update: StatuspageIncidentUpdate) -> Date {
        for raw in [update.updatedAt, update.displayAt, update.createdAt] {
            if let raw, let parsed = ISO8601Parsing.parse(raw) { return parsed }
        }
        return .distantPast
    }

    private func level(for token: String) -> ServiceStatusLevel {
        switch token.lowercased() {
        case "none", "operational":
            return .operational
        case "maintenance", "under_maintenance":
            return .maintenance
        case "minor", "degraded_performance":
            return .degradedPerformance
        case "major", "partial_outage":
            return .partialOutage
        case "critical", "major_outage":
            return .majorOutage
        default:
            return .unknown
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
        let cleaned = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                || scalar == "\n" || scalar == "\t"
        }
        let value = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(limit))
    }
}
