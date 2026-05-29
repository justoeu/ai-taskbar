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
        let count = models?.count ?? 0
        // No quota signal from this endpoint — the row is a 0% status anchor
        // whose detail line carries the model count. Mirrors the Kimi balance
        // pattern (flat row + descriptive detail).
        let detail: String
        if count == 0 {
            detail = "API key valid (no models visible)"
        } else if count == 1 {
            detail = "1 model available"
        } else {
            detail = "\(count) models available"
        }
        let status = UsageWindow(
            label: "API Key",
            utilizationPercent: 0,
            resetsAt: nil,
            detail: detail
        )
        return GeminiSnapshot(
            planLabel: "Google AI Studio",
            status: status,
            modelCount: count
        )
    }
}
