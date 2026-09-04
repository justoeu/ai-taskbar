import Foundation

public struct StatuspagePage: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let url: String?
    public let timeZone: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url
        case timeZone = "time_zone"
        case updatedAt = "updated_at"
    }
}

public struct StatuspageStatus: Codable, Sendable, Equatable {
    public let indicator: String
    public let description: String
}

public struct StatuspageComponent: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let status: String
    public let createdAt: String?
    public let updatedAt: String?
    public let position: Int?
    public let description: String?
    public let groupID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, position, description
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case groupID = "group_id"
    }
}

public struct StatuspageAffectedComponent: Codable, Sendable, Equatable {
    public let code: String
    public let name: String
    public let oldStatus: String?
    public let newStatus: String?

    enum CodingKeys: String, CodingKey {
        case code, name
        case oldStatus = "old_status"
        case newStatus = "new_status"
    }
}

public struct StatuspageIncidentUpdate: Codable, Sendable, Equatable {
    public let id: String
    public let status: String
    public let body: String?
    public let incidentID: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let displayAt: String?
    public let affectedComponents: [StatuspageAffectedComponent]?

    enum CodingKeys: String, CodingKey {
        case id, status, body
        case incidentID = "incident_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case displayAt = "display_at"
        case affectedComponents = "affected_components"
    }
}

public struct StatuspageIncident: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let status: String
    public let impact: String
    public let createdAt: String
    public let updatedAt: String
    public let startedAt: String?
    public let resolvedAt: String?
    public let shortlink: String?
    public let scheduledFor: String?
    public let scheduledUntil: String?
    public let components: [StatuspageComponent]?
    public let incidentUpdates: [StatuspageIncidentUpdate]

    enum CodingKeys: String, CodingKey {
        case id, name, status, impact, components
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case resolvedAt = "resolved_at"
        case shortlink
        case scheduledFor = "scheduled_for"
        case scheduledUntil = "scheduled_until"
        case incidentUpdates = "incident_updates"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        impact = try container.decode(String.self, forKey: .impact)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        resolvedAt = try container.decodeIfPresent(String.self, forKey: .resolvedAt)
        shortlink = try container.decodeIfPresent(String.self, forKey: .shortlink)
        scheduledFor = try container.decodeIfPresent(String.self, forKey: .scheduledFor)
        scheduledUntil = try container.decodeIfPresent(String.self, forKey: .scheduledUntil)
        components = try container.decodeIfPresent([StatuspageComponent].self, forKey: .components)
        incidentUpdates = try container.decodeIfPresent(
            [StatuspageIncidentUpdate].self,
            forKey: .incidentUpdates
        ) ?? []
    }
}

public struct StatuspageSummary: Codable, Sendable, Equatable {
    public let page: StatuspagePage
    public let status: StatuspageStatus
    public let components: [StatuspageComponent]
    public let incidents: [StatuspageIncident]
    public let scheduledMaintenances: [StatuspageIncident]

    enum CodingKeys: String, CodingKey {
        case page, status, components, incidents
        case scheduledMaintenances = "scheduled_maintenances"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decode(StatuspagePage.self, forKey: .page)
        status = try container.decode(StatuspageStatus.self, forKey: .status)
        components = try container.decode([StatuspageComponent].self, forKey: .components)
        incidents = try container.decodeIfPresent([StatuspageIncident].self, forKey: .incidents) ?? []
        scheduledMaintenances = try container.decodeIfPresent(
            [StatuspageIncident].self,
            forKey: .scheduledMaintenances
        ) ?? []
    }
}

public struct StatuspageIncidentList: Codable, Sendable, Equatable {
    public let page: StatuspagePage?
    public let incidents: [StatuspageIncident]

    public init(page: StatuspagePage? = nil, incidents: [StatuspageIncident]) {
        self.page = page
        self.incidents = incidents
    }

    enum CodingKeys: String, CodingKey { case page, incidents }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decodeIfPresent(StatuspagePage.self, forKey: .page)
        incidents = try container.decode([StatuspageIncident].self, forKey: .incidents)
    }
}

public struct StatuspageMaintenanceList: Codable, Sendable, Equatable {
    public let page: StatuspagePage?
    public let scheduledMaintenances: [StatuspageIncident]

    public init(page: StatuspagePage? = nil,
                scheduledMaintenances: [StatuspageIncident]) {
        self.page = page
        self.scheduledMaintenances = scheduledMaintenances
    }

    enum CodingKeys: String, CodingKey {
        case page
        case scheduledMaintenances = "scheduled_maintenances"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decodeIfPresent(StatuspagePage.self, forKey: .page)
        scheduledMaintenances = try container.decode(
            [StatuspageIncident].self,
            forKey: .scheduledMaintenances
        )
    }
}

/// Cache payload composed from the three official Statuspage endpoints.
public struct StatuspageCachedPayload: Codable, Sendable, Equatable {
    public let summary: StatuspageSummary
    public let incidents: StatuspageIncidentList
    public let scheduledMaintenances: StatuspageMaintenanceList

    public init(
        summary: StatuspageSummary,
        incidents: StatuspageIncidentList,
        scheduledMaintenances: StatuspageMaintenanceList
    ) {
        self.summary = summary
        self.incidents = incidents
        self.scheduledMaintenances = scheduledMaintenances
    }
}
