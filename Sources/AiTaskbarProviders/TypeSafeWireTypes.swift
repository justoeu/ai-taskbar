import Foundation
import AiTaskbarCore

/// `GET https://api.typesafe.ai/v1/models` — verified verbatim with a real key
/// on 2026-09-29 (docs/SDD-typesafe-jev.md, Appendix A). The list carries the
/// aliases only (`jev-latest`, `jev-preview`), never the version they resolve
/// to, and `release_date` has microsecond precision
/// (`2026-09-10T18:38:01.391457+00:00`).
public struct TypeSafeModelsResponse: Decodable {
    public let models: [TypeSafeModelEntry]

    enum CodingKeys: String, CodingKey { case models }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `models` is the one field the card needs; a missing list is a schema
        // change, not an empty account.
        let raw = try c.decode([LenientEntry].self, forKey: .models)
        models = raw.compactMap(\.entry)
    }

    /// Skips an entry without a usable `name` instead of failing the whole
    /// list, so one odd item cannot blank the card.
    private struct LenientEntry: Decodable {
        let entry: TypeSafeModelEntry?
        init(from decoder: Decoder) throws {
            entry = try? TypeSafeModelEntry(from: decoder)
        }
    }
}

public struct TypeSafeModelEntry: Decodable {
    public let name: String
    public let description: String?
    public let release_date: String?

    enum CodingKeys: String, CodingKey { case name, description, release_date }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = try c.decode(String.self, forKey: .name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "empty model name")
        }
        name = rawName
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        release_date = try? c.decodeIfPresent(String.self, forKey: .release_date)
    }
}

/// Error body: `{"detail":{"error_type":"authentication_error","message":"…"}}`
/// (401 invalid key, 403 missing key); a 404 sends `{"detail":"Not Found"}`.
public struct TypeSafeErrorResponse: Decodable {
    public let errorType: String?
    public let message: String?

    enum CodingKeys: String, CodingKey { case detail }
    enum DetailKeys: String, CodingKey { case error_type, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let d = try? c.nestedContainer(keyedBy: DetailKeys.self, forKey: .detail) {
            errorType = try? d.decodeIfPresent(String.self, forKey: .error_type)
            message = try? d.decodeIfPresent(String.self, forKey: .message)
        } else {
            errorType = nil
            message = try? c.decodeIfPresent(String.self, forKey: .detail)
        }
    }
}

extension TypeSafeModelsResponse {
    public func toSnapshot() -> TypeSafeSnapshot {
        TypeSafeSnapshot(
            planLabel: nil,
            models: models.map {
                TypeSafeModel(name: $0.name,
                              description: $0.description,
                              releaseDate: $0.release_date.flatMap(ISO8601Parsing.parse))
            },
            billing: nil
        )
    }
}
