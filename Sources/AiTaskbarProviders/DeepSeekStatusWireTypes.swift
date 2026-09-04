import Foundation

public struct DeepSeekStatusEnvelope<Body>: Codable, Sendable, Equatable
where Body: Codable & Sendable & Equatable {
    public let requestID: String
    public let data: Body

    public init(requestID: String, data: Body) {
        self.requestID = requestID
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case data
    }
}

public struct DeepSeekStatusComponent: Codable, Sendable, Equatable {
    public let componentID: String
    public let sectionID: String?
    public let name: String
    public let description: String?
    public let availableSinceSeconds: Int64
    public let orderID: Int
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case sectionID = "section_id"
        case name, description, status
        case availableSinceSeconds = "available_since_seconds"
        case orderID = "order_id"
    }
}

public struct DeepSeekStatusSection: Codable, Sendable, Equatable {
    public let sectionID: String
    public let name: String
    public let description: String?
    public let orderID: Int
    public let hideUptime: Bool
    public let hideAll: Bool

    enum CodingKeys: String, CodingKey {
        case sectionID = "section_id"
        case name, description
        case orderID = "order_id"
        case hideUptime = "hide_uptime"
        case hideAll = "hide_all"
    }
}

public struct DeepSeekStatusPage: Codable, Sendable, Equatable {
    public let pageID: Int64
    public let name: String
    public let urlName: String
    public let type: String
    public let customDomain: String
    public let logo: String?
    public let logoURL: String?
    public let dateView: String?
    public let displayUptimeMode: String?
    public let components: [DeepSeekStatusComponent]
    public let sections: [DeepSeekStatusSection]

    enum CodingKeys: String, CodingKey {
        case pageID = "page_id"
        case name
        case urlName = "url_name"
        case type
        case customDomain = "custom_domain"
        case logo
        case logoURL = "logo_url"
        case dateView = "date_view"
        case displayUptimeMode = "display_uptime_mode"
        case components, sections
    }
}

public struct DeepSeekComponentChange: Codable, Sendable, Equatable {
    public let componentID: String
    public let componentName: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case componentName = "component_name"
        case status
    }
}

public struct DeepSeekChangeUpdate: Codable, Sendable, Equatable {
    public let updateID: String
    public let atSeconds: Int64
    public let status: String
    public let description: String?
    public let componentChanges: [DeepSeekComponentChange]

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case atSeconds = "at_seconds"
        case status, description
        case componentChanges = "component_changes"
    }
}

public struct DeepSeekStatusChange: Codable, Sendable, Equatable {
    public let changeID: Int64
    public let pageID: Int64
    public let type: String
    public let title: String
    public let description: String?
    public let status: String
    public let affectedComponents: [DeepSeekStatusComponent]
    public let startAtSeconds: Int64
    public let closeAtSeconds: Int64?
    public let updates: [DeepSeekChangeUpdate]
    public let notifySubscribers: Bool

    enum CodingKeys: String, CodingKey {
        case changeID = "change_id"
        case pageID = "page_id"
        case type, title, description, status, updates
        case affectedComponents = "affected_components"
        case startAtSeconds = "start_at_seconds"
        case closeAtSeconds = "close_at_seconds"
        case notifySubscribers = "notify_subscribers"
    }
}

public struct DeepSeekActiveStatus: Codable, Sendable, Equatable {
    public let page: DeepSeekStatusPage
    public let activeChanges: [DeepSeekStatusChange]

    enum CodingKeys: String, CodingKey {
        case page
        case activeChanges = "active_changes"
    }
}

public struct DeepSeekStatusImpact: Codable, Sendable, Equatable {
    public let componentID: String?
    public let sectionID: String?
    public let changeID: Int64
    public let startAtSeconds: Int64
    public let endAtSeconds: Int64
    public let status: String

    enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case sectionID = "section_id"
        case changeID = "change_id"
        case startAtSeconds = "start_at_seconds"
        case endAtSeconds = "end_at_seconds"
        case status
    }
}

public struct DeepSeekStatusUptime: Codable, Sendable, Equatable {
    public let componentID: String?
    public let sectionID: String?
    public let uptime: Double
    public let availableSinceSeconds: Int64

    enum CodingKeys: String, CodingKey {
        case componentID = "component_id"
        case sectionID = "section_id"
        case uptime
        case availableSinceSeconds = "available_since_seconds"
    }
}

public struct DeepSeekLinkedChange: Codable, Sendable, Equatable {
    public let id: Int64
    public let type: String
    public let title: String
}

public struct DeepSeekStatusStructure: Codable, Sendable, Equatable {
    public let sectionImpacts: [DeepSeekStatusImpact]
    public let sectionUptimes: [DeepSeekStatusUptime]
    public let componentImpacts: [DeepSeekStatusImpact]
    public let componentUptimes: [DeepSeekStatusUptime]
    public let linkedChanges: [DeepSeekLinkedChange]

    enum CodingKeys: String, CodingKey {
        case sectionImpacts = "section_impacts"
        case sectionUptimes = "section_uptimes"
        case componentImpacts = "component_impacts"
        case componentUptimes = "component_uptimes"
        case linkedChanges = "linked_changes"
    }
}

public struct DeepSeekChangeList: Codable, Sendable, Equatable {
    public let items: [DeepSeekStatusChange]
}

/// Combined cache payload from the three official FlashDuty endpoints.
public struct DeepSeekStatusPayload: Codable, Sendable, Equatable {
    public let active: DeepSeekStatusEnvelope<DeepSeekActiveStatus>
    public let structure: DeepSeekStatusEnvelope<DeepSeekStatusStructure>
    public let changes: DeepSeekStatusEnvelope<DeepSeekChangeList>

    public init(
        active: DeepSeekStatusEnvelope<DeepSeekActiveStatus>,
        structure: DeepSeekStatusEnvelope<DeepSeekStatusStructure>,
        changes: DeepSeekStatusEnvelope<DeepSeekChangeList>
    ) {
        self.active = active
        self.structure = structure
        self.changes = changes
    }
}
