import Foundation

/// A single rolling-window quota reading (Anthropic session/weekly, OpenAI 5h/7d, etc.).
public struct UsageWindow: Sendable, Equatable, Codable {
    /// Label shown in the UI ("Session 5h", "Weekly 7d", "Sonnet 7d", ...).
    public let label: String
    /// 0...100 (or higher if the vendor reports overuse). Always passed
    /// through `UtilizationPercent.sanitized` — at init AND on decode from
    /// the cache — so it is never NaN, negative, or above 1000.
    public let utilizationPercent: Double
    /// When the window resets (absolute time). May be nil if the vendor only
    /// reports a "seconds-until-reset" without an anchor.
    public let resetsAt: Date?
    /// Best human-readable detail line (e.g. "1 of 250 messages", "$2.45 / $5.00").
    public let detail: String?

    public init(label: String,
                utilizationPercent: Double,
                resetsAt: Date? = nil,
                detail: String? = nil) {
        self.label = label
        self.utilizationPercent = UtilizationPercent.sanitized(utilizationPercent)
        self.resetsAt = resetsAt
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case label, utilizationPercent, resetsAt, detail
    }

    /// Decodes through `init` so a snapshot cached by an older build (or a
    /// tampered cache file) cannot bypass the sanitization.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(label: try c.decode(String.self, forKey: .label),
                  utilizationPercent: try c.decode(Double.self, forKey: .utilizationPercent),
                  resetsAt: try c.decodeIfPresent(Date.self, forKey: .resetsAt),
                  detail: try c.decodeIfPresent(String.self, forKey: .detail))
    }

    /// True once `resetsAt` has passed but a fresh snapshot hasn't landed
    /// yet. The UI shows an "awaiting auto-refresh" message in this phase
    /// instead of letting a relative-date countdown count back up.
    public func isAwaitingReset(now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}
