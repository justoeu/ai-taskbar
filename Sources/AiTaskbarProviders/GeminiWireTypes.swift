import Foundation
import AiTaskbarCore

/// `GET <baseURL>/models` — the only stable, authenticated endpoint on the
/// public Generative Language API. Used as a heartbeat: it validates the API
/// key and reports how many models are visible to the caller. The shape below
/// covers the documented fields; only `models[].name` is required for the
/// snapshot.
public struct GeminiModelsResponse: Decodable, Sendable {
    public let models: [GeminiModel]?
    public let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case models
        case nextPageToken
    }
}

public struct GeminiModel: Decodable, Sendable {
    public let name: String?
    public let displayName: String?
    public let supportedGenerationMethods: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName
        case supportedGenerationMethods
    }
}

extension GeminiModelsResponse {
    public func toSnapshot() -> GeminiSnapshot {
        // Distinguish the three observable response shapes so a future
        // Google v1beta rename (e.g. `models` → `availableModels`) doesn't
        // silently render as a successful "no models visible" forever.
        //
        // - models == nil  → field missing/null. Treat as a schema warning.
        // - models == []   → key valid, but no models granted (real case
        //                     for new accounts before activation).
        // - models == [..] → expected case, surface the count.
        let detail: String
        let count: Int
        if let models {
            count = models.count
            detail = (count == 1) ? "1 model available"
                                   : "\(count) models available"
            if count == 0 {
                // `models` present but empty — genuine "no models granted"
                // state. Overwrite the count-zero phrasing above.
                return GeminiSnapshot(
                    planLabel: "Google AI Studio",
                    status: UsageWindow(label: "API Key",
                                        utilizationPercent: 0,
                                        resetsAt: nil,
                                        detail: "API key valid (no models visible)"),
                    modelCount: 0,
                    disclaimer: "Para conseguir monitorar o Gemini, é necessário ter o Antigravity instalado e autenticado."
                )
            }
        } else {
            count = 0
            detail = "Unexpected response shape — check base_url / API version"
        }
        return GeminiSnapshot(
            planLabel: "Google AI Studio",
            status: UsageWindow(label: "API Key",
                                utilizationPercent: 0,
                                resetsAt: nil,
                                detail: detail),
            modelCount: count,
            disclaimer: "Para conseguir monitorar o Gemini, é necessário ter o Antigravity instalado e autenticado."
        )
    }
}

// MARK: - Antigravity Quota Wire Types

/// Response from `agy --output-format json --print "/usage"`.
public struct AntigravityUsageResponse: Decodable, Sendable {
    public let conversationId: String?
    public let status: String?
    public let response: String?
    public let command: AntigravityCommand?

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case status
        case response
        case command
    }
}

public struct AntigravityCommand: Decodable, Sendable {
    public let name: String?
    public let data: AntigravityCommandData?
}

public struct AntigravityCommandData: Decodable, Sendable {
    public let description: String?
    public let groups: [AntigravityGroup]?
}

public struct AntigravityGroup: Decodable, Sendable {
    public let name: String?
    public let description: String?
    public let buckets: [AntigravityBucket]?
}

public struct AntigravityBucket: Decodable, Sendable {
    public let id: String?
    public let name: String?
    public let description: String?
    public let window: String?
    public let remainingFraction: Double?
    public let resetTime: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case window
        case remainingFraction = "remaining_fraction"
        case resetTime = "reset_time"
    }
}

extension AntigravityUsageResponse {
    public func toSnapshot(disclaimer: String? = nil) -> GeminiSnapshot {
        var fiveHour: UsageWindow?
        var weekly: UsageWindow?
        var thirdParty5Hour: UsageWindow?
        var thirdPartyWeekly: UsageWindow?

        let resolvedDisclaimer = disclaimer ?? "Para conseguir monitorar o Gemini, é necessário ter o Antigravity instalado e autenticado."

        if let groups = command?.data?.groups {
            for group in groups {
                let gName = (group.name ?? "").lowercased()
                let isGemini = gName.contains("gemini")
                let isThirdParty = gName.contains("claude") || gName.contains("gpt") || gName.contains("3p")

                for bucket in group.buckets ?? [] {
                    let bId = (bucket.id ?? "").lowercased()
                    let bWin = (bucket.window ?? "").lowercased()
                    let is5h = bWin == "5h" || bId.contains("5h")
                    let isWeekly = bWin == "weekly" || bId.contains("weekly")

                    let rem = bucket.remainingFraction ?? 1.0
                    let consumedFraction = max(0.0, min(1.0, 1.0 - rem))
                    let util = consumedFraction * 100.0
                    let resetsAt = bucket.resetTime.flatMap(ISO8601Parsing.parse)
                    let remPercentInt = Int((rem * 100.0).rounded())
                    let detail = "\(remPercentInt)% remaining"

                    if isGemini {
                        if is5h {
                            fiveHour = UsageWindow(label: "Gemini (5h)",
                                                   utilizationPercent: util,
                                                   resetsAt: resetsAt,
                                                   detail: detail)
                        } else if isWeekly {
                            weekly = UsageWindow(label: "Gemini (Weekly)",
                                                 utilizationPercent: util,
                                                 resetsAt: resetsAt,
                                                 detail: detail)
                        }
                    } else if isThirdParty {
                        if is5h {
                            thirdParty5Hour = UsageWindow(label: "Claude & GPT (5h)",
                                                          utilizationPercent: util,
                                                          resetsAt: resetsAt,
                                                          detail: detail)
                        } else if isWeekly {
                            thirdPartyWeekly = UsageWindow(label: "Claude & GPT (Weekly)",
                                                           utilizationPercent: util,
                                                           resetsAt: resetsAt,
                                                           detail: detail)
                        }
                    }
                }
            }
        }

        return GeminiSnapshot(
            planLabel: "Antigravity",
            status: nil,
            modelCount: nil,
            fiveHour: fiveHour,
            weekly: weekly,
            thirdParty5Hour: thirdParty5Hour,
            thirdPartyWeekly: thirdPartyWeekly,
            disclaimer: resolvedDisclaimer,
            isAntigravityActive: true
        )
    }
}
