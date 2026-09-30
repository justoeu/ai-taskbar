import Foundation
import AiTaskbarCore

/// Parsing for the TypeSafe console (phase 2, docs/SDD-typesafe-jev.md §16).
/// Every shape here was captured with a real session on 2026-09-29. The
/// console also returns personal data (`invoiceEmail`, `billingAddress`,
/// `paymentMethod`, `payments`, per-bucket `userEmail` / `userId`, key ids and
/// names): none of it is ever decoded — only the fields named below exist.
public enum TypeSafeConsoleParsing {
    public static let origin = "https://console.typesafe.ai"
    public static let host = "console.typesafe.ai"
    /// The server action the billing page itself calls to render.
    public static let billingActionName = "getBillingOverviewResult"
    public static let maxChunks = 60

    private static let scriptSrc = try! NSRegularExpression(
        pattern: #"<script\b[^>]*\bsrc=["']([^"']+)["'][^>]*>"#, options: .caseInsensitive)
    private static let actionID = try! NSRegularExpression(
        pattern: #""([0-9a-f]{40,})"[^)]{0,150}"getBillingOverviewResult""#, options: .caseInsensitive)
    /// The RSC tree of the login screen: `"(auth)",{"children":["login"`,
    /// with or without escaped quotes.
    private static let loginLanding = try! NSRegularExpression(
        pattern: #"\\?"\(auth\)\\?",\{\\?"children\\?":\[\\?"login\\?""#)

    /// Same-origin `.js` chunk URLs from the page, deduplicated, at most
    /// `maxChunks`. Chunks whose path mentions billing come first: that is
    /// where the action id lives, so discovery usually takes one download.
    public static func chunkURLs(inPage html: String) -> [URL] {
        var urls: [URL] = []
        for m in scriptSrc.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            let src = String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
            let absolute = src.hasPrefix("/") && !src.hasPrefix("//") ? origin + src : src
            guard let url = URL(string: absolute), url.scheme == "https", url.host == host,
                  url.port == nil, url.user == nil, url.path.hasSuffix(".js"),
                  !urls.contains(url) else { continue }
            urls.append(url)
        }
        let billingFirst = urls.filter { $0.path.localizedCaseInsensitiveContains("billing") }
            + urls.filter { !$0.path.localizedCaseInsensitiveContains("billing") }
        return Array(billingFirst.prefix(maxChunks))
    }

    public static func actionID(inChunk js: String) -> String? {
        guard let m = actionID.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
              let r = Range(m.range(at: 1), in: js) else { return nil }
        return String(js[r]).lowercased()
    }

    public static func isLoginLanding(_ html: String) -> Bool {
        loginLanding.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil
    }

    /// A Cloudflare interstitial, not the app: never read as "signed out".
    public static func isCloudflareChallenge(status: Int, headers: [AnyHashable: Any], body: String) -> Bool {
        let mitigated = headers.first { String(describing: $0.key).lowercased() == "cf-mitigated" }
        if mitigated != nil { return true }
        guard status == 403 || status == 503 else { return false }
        return body.contains("Just a moment...") || body.contains("Attention Required! | Cloudflare")
    }

    /// The billing overview from a `text/x-component` body: one `<id>:<json>`
    /// record per line, the result being the first object with an `ok` key.
    public static func billing(fromRSC body: String) throws -> TypeSafeBilling {
        for line in body.split(whereSeparator: \.isNewline) {
            guard let sep = line.firstIndex(of: ":"), sep > line.startIndex else { continue }
            let json = line[line.index(after: sep)...]
            guard json.first == "{",
                  let result = try? SharedCoders.decoder.decode(RSCResult.self, from: Data(json.utf8))
            else { continue }
            guard result.ok else { throw AppError.schema("typesafe billing: ok=false") }
            guard let billing = result.data?.billing else {
                throw AppError.schema("typesafe billing: no data.billing")
            }
            return try billing.toModel()
        }
        throw AppError.schema("typesafe billing: no result record")
    }

    private struct RSCResult: Decodable {
        let ok: Bool
        let data: DataField?
        struct DataField: Decodable {
            let billing: BillingWire?
            enum CodingKeys: String, CodingKey { case billing }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                billing = try c.decodeIfPresent(BillingWire.self, forKey: .billing)
            }
        }
    }

    struct BillingWire: Decodable {
        let spent: Double?
        let balance: Double?
        let purchased: Double?
        let freeCreditsRemaining: Double?
        let plan: String?
        let cycleLabel: String?
        let resetsInDays: Double?
        let credits: [CreditWire]

        enum CodingKeys: String, CodingKey {
            case spent, balance, purchased, freeCreditsRemaining, plan, cycleLabel, resetsInDays, credits
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            spent = try? c.decodeIfPresent(Double.self, forKey: .spent)
            balance = try? c.decodeIfPresent(Double.self, forKey: .balance)
            purchased = try? c.decodeIfPresent(Double.self, forKey: .purchased)
            freeCreditsRemaining = try? c.decodeIfPresent(Double.self, forKey: .freeCreditsRemaining)
            plan = try? c.decodeIfPresent(String.self, forKey: .plan)
            cycleLabel = try? c.decodeIfPresent(String.self, forKey: .cycleLabel)
            resetsInDays = try? c.decodeIfPresent(Double.self, forKey: .resetsInDays)
            // One odd credit must not blank the card; a non-array (an RSC
            // reference like "$1:…") reads as no credits.
            let raw = (try? c.decodeIfPresent([Lenient<CreditWire>].self, forKey: .credits)) ?? nil
            credits = raw?.compactMap(\.value) ?? []
        }

        /// `spent` and `balance` are mandatory and finite: a missing number is
        /// a schema change, never a zero (SDD §16.5).
        func toModel() throws -> TypeSafeBilling {
            guard let spent, spent.isFinite, let balance, balance.isFinite else {
                throw AppError.schema("typesafe billing: spent/balance missing")
            }
            func finite(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
            let days = finite(resetsInDays).flatMap { $0 >= 0 && $0 < 400 ? Int(checkedTruncating: $0) : nil }
            let live = credits
                .compactMap { $0.toModel() }
                .filter { $0.remainingUSD > 0 }
                .sorted { $0.expiresAt < $1.expiresAt }
            return TypeSafeBilling(spentUSD: spent, balanceUSD: balance,
                                   purchasedUSD: finite(purchased),
                                   freeCreditsRemainingUSD: finite(freeCreditsRemaining),
                                   plan: plan?.isEmpty == false ? plan : nil,
                                   cycleLabel: cycleLabel?.isEmpty == false ? cycleLabel : nil,
                                   cycleEndsInDays: days, credits: live)
        }
    }

    struct CreditWire: Decodable {
        let amount: Double
        let remaining: Double
        let expiresAt: String
        let reason: String?

        func toModel() -> TypeSafeCredit? {
            guard amount.isFinite, remaining.isFinite, let date = ISO8601Parsing.parse(expiresAt) else { return nil }
            return TypeSafeCredit(amountUSD: amount, remainingUSD: remaining, expiresAt: date, reason: reason)
        }
    }

    struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}

/// `GET /api/usage?granularity=hour|day` — `{"buckets":[…]}`, one bucket per
/// (period, API key). Only the period and the three counters are decoded.
public struct TypeSafeUsageResponse: Decodable {
    public let buckets: [TypeSafeUsageBucket]

    enum CodingKeys: String, CodingKey { case buckets }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([TypeSafeConsoleParsing.Lenient<TypeSafeUsageBucket>].self, forKey: .buckets)
        buckets = raw.compactMap(\.value)
    }
}

public struct TypeSafeUsageBucket: Decodable, Equatable {
    /// Hour granularity: ISO date-time with offset; day: `YYYY-MM-DD`.
    public let day: String
    public let requests: Int
    public let inputTokens: Int
    public let outputTokens: Int

    enum CodingKeys: String, CodingKey { case day, requests, inputTokens, outputTokens }

    public init(day: String, requests: Int, inputTokens: Int, outputTokens: Int) {
        self.day = day
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        func count(_ k: CodingKeys) -> Int {
            let v = (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil
            guard let v, v >= 0 else { return 0 }
            return Int(checkedTruncating: v) ?? 0
        }
        requests = count(.requests)
        inputTokens = count(.inputTokens)
        outputTokens = count(.outputTokens)
    }
}

/// Folds usage buckets into what the card shows. Pure, so it is tested
/// without a clock.
public enum TypeSafeUsageMath {
    /// Hourly points kept for the sparkline.
    public static let hourlyLimit = 48

    public static func aggregate(hour: [TypeSafeUsageBucket], day: [TypeSafeUsageBucket],
                                 now: Date, calendar: Calendar = .current) -> TypeSafeUsage {
        var byHour: [Date: (Int, Int, Int)] = [:]
        for b in hour {
            guard let start = ISO8601Parsing.parse(b.day) else { continue }
            let acc = byHour[start] ?? (0, 0, 0)
            byHour[start] = (acc.0 &+ b.inputTokens, acc.1 &+ b.outputTokens, acc.2 &+ b.requests)
        }
        let points = byHour.keys.sorted().map {
            TypeSafeUsagePoint(start: $0, inputTokens: byHour[$0]!.0, outputTokens: byHour[$0]!.1,
                               requests: byHour[$0]!.2)
        }
        // Today = the user's local calendar day, from the hourly series.
        let todayStart = calendar.startOfDay(for: now)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let today = points.filter { $0.start >= todayStart && $0.start < todayEnd }

        // 7 days = today and the six before it, from the daily series. The
        // console labels days in UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let weekStart = utc.date(byAdding: .day, value: -6, to: utc.startOfDay(for: now)) ?? now
        let week = day.filter { b in
            guard let d = dayDate(b.day, calendar: utc) else { return false }
            return d >= weekStart && d <= now
        }
        return TypeSafeUsage(
            todayInputTokens: today.reduce(0) { $0 &+ $1.inputTokens },
            todayOutputTokens: today.reduce(0) { $0 &+ $1.outputTokens },
            todayRequests: today.reduce(0) { $0 &+ $1.requests },
            weekInputTokens: week.reduce(0) { $0 &+ $1.inputTokens },
            weekOutputTokens: week.reduce(0) { $0 &+ $1.outputTokens },
            weekRequests: week.reduce(0) { $0 &+ $1.requests },
            hourly: Array(points.suffix(hourlyLimit)))
    }

    static func dayDate(_ s: String, calendar: Calendar) -> Date? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0, radix: 10) }
        guard parts.count == 3 else { return ISO8601Parsing.parse(s) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
