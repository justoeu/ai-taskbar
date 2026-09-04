import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import AiTaskbarCore

public struct RSSStatusDescriptor: Sendable, Equatable {
    public let vendorId: VendorId
    public let statusPageURL: URL
    public let feedURL: URL

    public init(vendorId: VendorId, statusPageURL: URL, feedURL: URL) {
        self.vendorId = vendorId
        self.statusPageURL = statusPageURL
        self.feedURL = feedURL
    }

    public static let openRouter = RSSStatusDescriptor(
        vendorId: .openrouter,
        statusPageURL: URL(string: "https://status.openrouter.ai")!,
        feedURL: URL(string: "https://status.openrouter.ai/incidents.rss")!
    )

    public static let xAI = RSSStatusDescriptor(
        vendorId: .xai,
        statusPageURL: URL(string: "https://status.x.ai")!,
        feedURL: URL(string: "https://status.x.ai/feed.xml")!
    )
}

/// Official RSS incident-feed adapter. The feed proves declared incidents,
/// not live component health, so an empty/resolved-only result remains unknown.
public struct RSSStatusSource: ServiceStatusSource, Sendable {
    public static let maximumResponseBytes = 2 * 1024 * 1024
    public static let maximumItems = 200
    public static let maximumFieldCharacters = 4_096

    public let descriptor: RSSStatusDescriptor
    public var vendorId: VendorId { descriptor.vendorId }

    public init(descriptor: RSSStatusDescriptor) {
        self.descriptor = descriptor
    }

    public func fetchPayload(
        http: HTTPClient,
        now: Date
    ) async throws -> RSSStatusFeed {
        _ = now
        try Task.checkCancellation()
        try validateDescriptor()
        var request = URLRequest(url: descriptor.feedURL)
        request.httpMethod = "GET"
        let (data, response) = try await http.sendBounded(
            request,
            maximumResponseBytes: Self.maximumResponseBytes
        )
        try Task.checkCancellation()
        try validateResponse(data: data, response: response)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data.prefix(1_024), encoding: .utf8) ?? ""
            throw AppError.http(status: response.statusCode, body: body)
        }
        let feed = try Self.parse(data)
        try validateFeed(feed)
        try Task.checkCancellation()
        return feed
    }

    public func makeStatus(
        from payload: RSSStatusFeed,
        now: Date
    ) throws -> VendorServiceStatus {
        guard payload.items.count <= Self.maximumItems else {
            throw AppError.schema("RSS item limit exceeded")
        }

        let dateParser = try RSSStatusDateParser()
        let mapped = try payload.items.map {
            try makeIncident($0, dateParser: dateParser)
        }
            .sorted { $0.updatedAt > $1.updatedAt }
        var ids = Set<String>()
        var titleStarts = Set<String>()
        var unique: [ServiceIncident] = []
        for incident in mapped {
            let pair = "\(normalized(incident.title))|\(Int64(incident.startedAt.timeIntervalSince1970))"
            guard !ids.contains(incident.id), !titleStarts.contains(pair) else { continue }
            ids.insert(incident.id)
            titleStarts.insert(pair)
            unique.append(incident)
        }

        let recent = ServiceStatusWindow.recentIncidents(unique, now: now)
        let active = recent.filter { $0.resolvedAt == nil && $0.startedAt <= now }
        let level = active.isEmpty
            ? ServiceStatusLevel.unknown
            : ServiceStatusWindow.worstLevel(in: active.map(\.level))
        let summary: String
        if active.isEmpty {
            summary = ""
        } else {
            summary = active.max {
                let left = severity($0.level)
                let right = severity($1.level)
                return left == right ? $0.updatedAt < $1.updatedAt : left < right
            }?.title ?? ""
        }

        let sourceUpdatedAt: Date?
        if let raw = payload.lastBuildDate {
            guard let parsed = dateParser.parseFeedDate(raw) else {
                throw AppError.schema("RSS invalid lastBuildDate")
            }
            sourceUpdatedAt = parsed
        } else {
            sourceUpdatedAt = nil
        }

        return VendorServiceStatus(
            vendorId: descriptor.vendorId,
            level: level,
            coverage: .incidentsOnly,
            summary: summary,
            sourceURL: descriptor.statusPageURL,
            sourceUpdatedAt: sourceUpdatedAt,
            incidents: recent
        )
    }

    public static func parse(_ data: Data) throws -> RSSStatusFeed {
        guard data.count <= maximumResponseBytes else {
            throw AppError.schema("RSS response exceeds 2 MiB")
        }
        let delegate = RSSStatusParserDelegate(
            maximumItems: maximumItems,
            maximumFieldCharacters: maximumFieldCharacters
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            if let failure = delegate.failure { throw failure }
            let message = parser.parserError?.localizedDescription ?? "invalid XML"
            throw AppError.schema("RSS parse: \(message.prefix(300))")
        }
        if let failure = delegate.failure { throw failure }
        guard delegate.hasRSSChannel else {
            throw AppError.schema("RSS document is missing rss/channel")
        }
        return delegate.feed
    }

    private func validateDescriptor() throws {
        let expected: RSSStatusDescriptor?
        switch descriptor.vendorId {
        case .openrouter: expected = .openRouter
        case .xai: expected = .xAI
        default: expected = nil
        }
        let expectedHost = expected?.statusPageURL.host?.lowercased()
        let statusURLIsValid = validStaticURL(
            descriptor.statusPageURL,
            expectedHost: expectedHost
        )
        let feedURLIsValid = validStaticURL(
            descriptor.feedURL,
            expectedHost: expectedHost
        )
        guard let expected,
              descriptor == expected,
              descriptor.statusPageURL == descriptor.vendorId.statusPageURL,
              statusURLIsValid,
              feedURLIsValid
        else {
            throw AppError.schema("invalid RSS status HTTPS host for \(descriptor.vendorId.rawValue)")
        }
    }

    private func validStaticURL(_ url: URL, expectedHost: String?) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == expectedHost
            && url.user == nil
            && url.password == nil
            && url.port == nil
    }

    private func validateResponse(data: Data, response: HTTPURLResponse) throws {
        guard data.count <= Self.maximumResponseBytes else {
            throw AppError.schema("RSS response exceeds 2 MiB")
        }
        guard response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == descriptor.feedURL.host?.lowercased(),
              response.url?.user == nil,
              response.url?.password == nil,
              response.url?.port == nil
        else {
            throw AppError.transport("RSS status redirect left allowed host")
        }
    }

    private func validateFeed(_ feed: RSSStatusFeed) throws {
        guard feed.items.count <= Self.maximumItems,
              feed.items.allSatisfy({ !$0.title.isEmpty && !$0.pubDate.isEmpty }),
              feed.title.lowercased().contains(identityToken),
              feedLinkMatchesExpectedHost(feed.link)
        else {
            throw AppError.schema("RSS source identity, required fields, or item limit invalid")
        }
    }

    private var identityToken: String {
        descriptor.vendorId == .xai ? "xai" : "openrouter"
    }

    private func feedLinkMatchesExpectedHost(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedHost = descriptor.statusPageURL.host?.lowercased()
        if let url = URL(string: value), url.host != nil {
            return url.scheme?.lowercased() == "https"
                && url.host?.lowercased() == expectedHost
                && url.user == nil
                && url.password == nil
                && url.port == nil
        }
        return value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == expectedHost
    }

    private func makeIncident(
        _ item: RSSStatusItem,
        dateParser: RSSStatusDateParser
    ) throws -> ServiceIncident {
        guard let startedAt = dateParser.parseFeedDate(item.pubDate) else {
            throw AppError.schema("RSS invalid pubDate")
        }
        let title = plainText(item.title, limit: 300) ?? "Untitled incident"
        let message = plainText(item.description ?? "", limit: 1_000)
        let categoryText = item.categories.joined(separator: " ").lowercased()
        let searchable = ([title, message ?? ""] + item.categories)
            .joined(separator: " ")
            .lowercased()
        let categoryPhase = phase(for: categoryText)
        let phase = categoryPhase == .unknown ? phase(for: searchable) : categoryPhase
        let dates = dateParser.updateDates(
            in: item.description ?? "",
            publicationDate: startedAt,
            plainText: plainText
        )
        let updatedAt = max(dates.max() ?? startedAt, startedAt)
        let resolvedAt: Date?
        switch phase {
        case .resolved, .completed:
            resolvedAt = dateParser.resolvedDate(
                in: item.description ?? "",
                publicationDate: startedAt,
                plainText: plainText
            ) ?? updatedAt
        default:
            resolvedAt = nil
        }

        let categoryLevel = level(for: categoryText)
        var level = categoryLevel == .unknown ? level(for: searchable) : categoryLevel
        if level == .unknown && resolvedAt == nil {
            level = .degradedPerformance
        }
        let id = plainText(item.guid ?? "", limit: 200)
            ?? safeSourceURL(item.link)?.absoluteString
            ?? "\(normalized(title))-\(Int64(startedAt.timeIntervalSince1970))"

        return ServiceIncident(
            id: id,
            title: title,
            level: level,
            phase: phase,
            startedAt: startedAt,
            updatedAt: updatedAt,
            resolvedAt: resolvedAt,
            affectedComponents: componentNames(from: title),
            message: message,
            sourceURL: safeSourceURL(item.link)
        )
    }

    private func safeSourceURL(_ raw: String?) -> URL? {
        guard var raw = plainText(raw ?? "", limit: 1_000) else { return nil }
        let host = descriptor.statusPageURL.host?.lowercased() ?? ""
        if raw.lowercased().hasPrefix(host + "/") { raw = "https://" + raw }
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host,
              url.user == nil,
              url.password == nil,
              url.port == nil
        else { return nil }
        return url
    }

    private func componentNames(from title: String) -> [String] {
        guard title.first == "[", let end = title.firstIndex(of: "]") else { return [] }
        let name = String(title[title.index(after: title.startIndex)..<end])
        guard let clean = plainText(name, limit: 100) else { return [] }
        return [clean]
    }

    private func phase(for text: String) -> ServiceIncidentPhase {
        if text.contains("completed") { return .completed }
        if text.contains("resolved") { return .resolved }
        if text.contains("monitoring") { return .monitoring }
        if text.contains("identified") { return .identified }
        if text.contains("investigating") { return .investigating }
        if text.contains("in_progress") || text.contains("in progress") { return .inProgress }
        if text.contains("scheduled") { return .scheduled }
        return .unknown
    }

    private func level(for text: String) -> ServiceStatusLevel {
        if text.contains("maintenance") { return .maintenance }
        if text.contains("major_outage") || text.contains("full_outage")
            || text.contains("major outage") || text.contains("full outage") {
            return .majorOutage
        }
        if text.contains("partial_outage") || text.contains("partial outage")
            || text.contains(" unavailable") || text.contains("outage") {
            return .partialOutage
        }
        if text.contains("degraded") || text.contains("minor")
            || text.contains("high error") || text.contains("elevated error")
            || text.contains("reduced success") || text.contains("latency") {
            return .degradedPerformance
        }
        return .unknown
    }

    private func severity(_ level: ServiceStatusLevel) -> Int {
        switch level {
        case .unknown: return 0
        case .operational: return 1
        case .maintenance: return 2
        case .degradedPerformance: return 3
        case .partialOutage: return 4
        case .majorOutage: return 5
        }
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func plainText(_ raw: String, limit: Int) -> String? {
        var output = ""
        output.reserveCapacity(min(raw.count, limit))
        var insideTag = false
        for character in raw {
            if character == "<" {
                insideTag = true
                if output.last?.isWhitespace == false { output.append(" ") }
                continue
            }
            if character == ">" {
                insideTag = false
                continue
            }
            guard !insideTag, output.count < limit * 2 else { continue }
            output.append(character)
        }
        for _ in 0..<2 {
            output = output
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&apos;", with: "'")
        }
        let cleaned = output
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
        let normalized = String(String.UnicodeScalarView(cleaned))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(limit))
    }
}

/// One parser per feed conversion: formatter and regex setup is paid once,
/// while conversion remains synchronous and confined to the caller.
private final class RSSStatusDateParser {
    typealias PlainText = (String, Int) -> String?

    private let feedFormatter: DateFormatter
    private let shortFormatter: DateFormatter
    private let fullRegex: NSRegularExpression
    private let shortRegex: NSRegularExpression
    private let calendar = Calendar(identifier: .gregorian)

    init() throws {
        feedFormatter = DateFormatter()
        feedFormatter.locale = Locale(identifier: "en_US_POSIX")
        feedFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        feedFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        shortFormatter = DateFormatter()
        shortFormatter.locale = Locale(identifier: "en_US_POSIX")
        shortFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        shortFormatter.dateFormat = "MMM d, h:mm a zzz yyyy"

        fullRegex = try NSRegularExpression(
            pattern: #"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \d{1,2}:\d{2}:\d{2} (?:GMT|UTC)"#
        )
        shortRegex = try NSRegularExpression(
            pattern: #"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{1,2}, \d{1,2}:\d{2} [AP]M (?:GMT|UTC)"#
        )
    }

    func parseFeedDate(_ raw: String) -> Date? {
        feedFormatter.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func resolvedDate(
        in raw: String,
        publicationDate: Date,
        plainText: PlainText
    ) -> Date? {
        let plain = plainText(raw, RSSStatusSource.maximumFieldCharacters) ?? ""
        guard let range = plain.range(of: "Resolved:", options: .caseInsensitive) else {
            return nil
        }
        return updateDates(
            in: String(plain[range.upperBound...]),
            publicationDate: publicationDate,
            plainText: plainText
        )
        .filter { $0 >= publicationDate }
        .min()
    }

    func updateDates(
        in raw: String,
        publicationDate: Date,
        plainText: PlainText
    ) -> [Date] {
        let plain = plainText(raw, RSSStatusSource.maximumFieldCharacters) ?? ""
        let source = plain as NSString
        var result = fullRegex.matches(
            in: plain,
            range: NSRange(location: 0, length: source.length)
        ).compactMap { parseFeedDate(source.substring(with: $0.range)) }

        let publicationYear = calendar.component(.year, from: publicationDate)
        for match in shortRegex.matches(
            in: plain,
            range: NSRange(location: 0, length: source.length)
        ) {
            let rawDate = source.substring(with: match.range)
            let candidates = [publicationYear - 1, publicationYear, publicationYear + 1]
                .compactMap { shortFormatter.date(from: rawDate + " \($0)") }
            if let nearest = candidates.min(by: {
                abs($0.timeIntervalSince(publicationDate))
                    < abs($1.timeIntervalSince(publicationDate))
            }) {
                result.append(nearest)
            }
        }
        return result
    }
}

private final class RSSStatusParserDelegate: NSObject, XMLParserDelegate {
    private struct ItemBuilder {
        var title = ""
        var description: String?
        var pubDate = ""
        var link: String?
        var guid: String?
        var guidIsPermaLink: Bool?
        var categories: [String] = []
    }

    private let maximumItems: Int
    private let maximumFieldCharacters: Int
    private var channelTitle = ""
    private var channelLink: String?
    private var channelDescription: String?
    private var lastBuildDate: String?
    private var items: [RSSStatusItem] = []
    private var item: ItemBuilder?
    private var capturedElement: String?
    private var capturedText = ""
    private var guidIsPermaLink: Bool?
    private var sawRSSRoot = false
    private var sawChannel = false

    fileprivate private(set) var failure: AppError?
    fileprivate var hasRSSChannel: Bool { sawRSSRoot && sawChannel }
    fileprivate var feed: RSSStatusFeed {
        RSSStatusFeed(
            title: channelTitle,
            link: channelLink,
            description: channelDescription,
            lastBuildDate: lastBuildDate,
            items: items
        )
    }

    init(maximumItems: Int, maximumFieldCharacters: Int) {
        self.maximumItems = maximumItems
        self.maximumFieldCharacters = maximumFieldCharacters
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = normalized(elementName)
        if element == "rss" { sawRSSRoot = true }
        if element == "channel", sawRSSRoot { sawChannel = true }
        if element == "item" {
            guard items.count < maximumItems else {
                failure = AppError.schema("RSS item limit exceeded")
                parser.abortParsing()
                return
            }
            item = ItemBuilder()
            return
        }
        let isNamespacedLink = element == "link" && (
            elementName.contains(":")
                || qName?.contains(":") == true
                || namespaceURI?.isEmpty == false
                || attributeDict["href"] != nil
        )
        guard !isNamespacedLink else { return }
        guard ["title", "link", "description", "lastbuilddate", "pubdate", "guid", "category"]
            .contains(element) else { return }
        capturedElement = element
        capturedText = ""
        if element == "guid" {
            guidIsPermaLink = attributeDict["isPermaLink"].flatMap(Bool.init)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = normalized(elementName)
        if element == capturedElement {
            assign(capturedText.trimmingCharacters(in: .whitespacesAndNewlines), element: element)
            capturedElement = nil
            capturedText = ""
        }
        guard element == "item", let item else { return }
        items.append(RSSStatusItem(
            title: item.title,
            description: item.description,
            pubDate: item.pubDate,
            link: item.link,
            guid: item.guid,
            guidIsPermaLink: item.guidIsPermaLink,
            categories: Array(item.categories.prefix(20))
        ))
        self.item = nil
    }

    private func append(_ string: String) {
        guard capturedElement != nil, capturedText.count < maximumFieldCharacters else { return }
        capturedText.append(contentsOf: string.prefix(maximumFieldCharacters - capturedText.count))
    }

    private func assign(_ value: String, element: String) {
        if item != nil {
            switch element {
            case "title": item?.title = value
            case "description": item?.description = value
            case "pubdate": item?.pubDate = value
            case "link": item?.link = value
            case "guid":
                item?.guid = value
                item?.guidIsPermaLink = guidIsPermaLink
                guidIsPermaLink = nil
            case "category":
                if item?.categories.count ?? 0 < 20 { item?.categories.append(value) }
            default: break
            }
        } else {
            switch element {
            case "title": channelTitle = value
            case "link" where !value.isEmpty: channelLink = value
            case "description": channelDescription = value
            case "lastbuilddate": lastBuildDate = value
            default: break
            }
        }
    }

    private func normalized(_ element: String) -> String {
        element.split(separator: ":").last.map { String($0).lowercased() }
            ?? element.lowercased()
    }
}
