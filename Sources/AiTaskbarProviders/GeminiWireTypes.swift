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
                    modelCount: 0
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
            modelCount: count
        )
    }
}
