import Foundation

/// Reads/writes `~/.codex/auth.json`, preserving any top-level keys we don't
/// recognize so the Codex CLI's own state survives a refresh-write.
public struct FileCredentialReader: Sendable {
    public let path: URL

    public init(path: URL = Paths.defaultCodexAuth()) {
        self.path = path
    }

    public func read() throws -> CodexAuth {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw AppError.credentials(
                "Cannot read \(path.path): \(error.localizedDescription). " +
                "Run `codex login` to create it.")
        }
        let blob: [String: JSONValue]
        do {
            blob = try SharedCoders.decoder.decode([String: JSONValue].self, from: data)
        } catch {
            throw AppError.schema("\(path.lastPathComponent): \(error)")
        }
        // Pull the known fields out, stash everything else for round-trip.
        guard case let .object(tokensObj) = blob["tokens"] ?? .null else {
            throw AppError.schema("\(path.lastPathComponent) missing `tokens` object")
        }
        let tokens = try decodeTokens(from: tokensObj)
        var accountId: String?
        if case let .string(s) = blob["account_id"] ?? .null { accountId = s }
        else if case let .string(s) = blob["account-id"] ?? .null { accountId = s }

        var unknown = blob
        unknown.removeValue(forKey: "tokens")
        return CodexAuth(tokens: tokens, accountId: accountId, unknownTopLevel: unknown)
    }

    public func writeBack(_ updated: CodexAuth) throws {
        var blob = updated.unknownTopLevel
        blob["tokens"] = .object([
            "access_token":  .string(updated.tokens.accessToken),
            "refresh_token": .string(updated.tokens.refreshToken),
            "id_token":      .string(updated.tokens.idToken),
        ])
        if let acc = updated.accountId {
            blob["account_id"] = .string(acc)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(blob)
        try AtomicFileWrite.write(data, to: path, permissions: 0o600)
    }

    private func decodeTokens(from obj: [String: JSONValue]) throws -> CodexTokens {
        guard case let .string(access) = obj["access_token"] ?? .null else {
            throw AppError.schema("Codex auth.json missing `tokens.access_token`")
        }
        guard case let .string(refresh) = obj["refresh_token"] ?? .null else {
            throw AppError.schema("Codex auth.json missing `tokens.refresh_token`")
        }
        guard case let .string(idToken) = obj["id_token"] ?? .null else {
            throw AppError.schema("Codex auth.json missing `tokens.id_token`")
        }
        return CodexTokens(accessToken: access, refreshToken: refresh, idToken: idToken)
    }
}
