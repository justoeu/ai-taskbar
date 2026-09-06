import Foundation

public struct RSSStatusItem: Codable, Sendable, Equatable {
    public let title: String
    public let description: String?
    public let pubDate: String
    public let link: String?
    public let guid: String?
    public let guidIsPermaLink: Bool?
    public let categories: [String]

    public init(
        title: String,
        description: String?,
        pubDate: String,
        link: String?,
        guid: String?,
        guidIsPermaLink: Bool?,
        categories: [String]
    ) {
        self.title = title
        self.description = description
        self.pubDate = pubDate
        self.link = link
        self.guid = guid
        self.guidIsPermaLink = guidIsPermaLink
        self.categories = categories
    }
}

public struct RSSStatusFeed: Codable, Sendable, Equatable {
    public let title: String
    public let link: String?
    public let description: String?
    public let lastBuildDate: String?
    public let items: [RSSStatusItem]

    public init(
        title: String,
        link: String?,
        description: String?,
        lastBuildDate: String?,
        items: [RSSStatusItem]
    ) {
        self.title = title
        self.link = link
        self.description = description
        self.lastBuildDate = lastBuildDate
        self.items = items
    }
}
