import Foundation
import os.lock

/// Reads/writes `~/.codex/auth.json`, preserving any top-level keys we don't
/// recognize so the Codex CLI's own state survives a refresh-write.
///
/// **Class (not struct) since 0.x:** holds an in-memory `pendingUpdate` cache
/// that mirrors the most recent OAuth refresh whose `writeBack` was blocked
/// by an I/O failure. Without this cache, a successful `OAuth.refresh` call
/// that rotates the server-side refresh_token would leave the local
/// `auth.json` still holding the now-invalid pre-rotation token — logging
/// the user out of the CLI and the monitor simultaneously. The cache is
/// reconciled against the on-disk copy on every `read()`: whichever has the
/// later JWT `exp` wins. Cleared when the disk copy catches up or surpasses
/// it (e.g. Codex CLI re-auth wrote a fresher token). Mirrors the
/// `KeychainCredentialReader.pendingUpdate` pattern.
public final class FileCredentialReader: @unchecked Sendable {
    public let path: URL

    private struct LockedState {
        var pendingUpdate: CodexAuth?
    }
    private let state = OSAllocatedUnfairLock(initialState: LockedState())

    public init(path: URL = Paths.defaultCodexAuth()) {
        self.path = path
    }

    public func read() throws -> CodexAuth {
        // Try disk read; tolerate failure because pendingUpdate may cover it.
        let diskResult: Result<CodexAuth, Error>
        do {
            diskResult = .success(try readFromDisk())
        } catch {
            diskResult = .failure(error)
        }
        let pending = state.withLock { $0.pendingUpdate }

        // Reuse the freshness-wins reconciliation from CredentialReconciliation.
        // CodexAuth doesn't expose expiresAtMs directly — derive it from the
        // JWT id_token so we can rank candidates the same way AnthropicCredentials does.
        let disk = try? diskResult.get()
        guard let verdict = CodexReconciliation.pick(disk: disk, pending: pending) else {
            // Neither copy available — surface the original disk error.
            switch diskResult {
            case .failure(let err): throw err
            case .success:          throw AppError.credentials("no Codex credentials available")
            }
        }
        if verdict.dropPending {
            state.withLock { $0.pendingUpdate = nil }
        }
        return verdict.credentials
    }

    public func writeBack(_ updated: CodexAuth) throws {
        do {
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
            // Disk won — drop any stale pending copy.
            state.withLock { $0.pendingUpdate = nil }
        } catch {
            // I/O failure AFTER the server already rotated the refresh_token.
            // Stash the rotated copy in memory BEFORE re-throwing so the next
            // read() can serve it instead of the now-invalid on-disk token.
            // Without this branch the user would be logged out of both the
            // CLI and the monitor until they manually re-auth.
            state.withLock { $0.pendingUpdate = updated }
            throw error
        }
    }

    private func readFromDisk() throws -> CodexAuth {
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

/// Pure reconciliation for `CodexAuth`. Mirrors `CredentialReconciliation`
/// but reads freshness from the JWT `exp` claim in `tokens.idToken` instead
/// of a stored `expiresAtMs`. Returns nil iff both inputs are nil.
public enum CodexReconciliation {
    public struct Verdict: Equatable {
        public let credentials: CodexAuth
        /// True when disk won — caller should clear the in-memory pending copy.
        public let dropPending: Bool
    }

    public static func pick(disk: CodexAuth?, pending: CodexAuth?) -> Verdict? {
        switch (disk, pending) {
        case (.some(let d), .some(let p)):
            // Freshness-wins via JWT exp. Falls back to disk on ties so a
            // Codex CLI re-auth that wrote the same exp recovers cleanly.
            let dExp = expiryMs(of: d) ?? Int64.min
            let pExp = expiryMs(of: p) ?? Int64.min
            if dExp >= pExp {
                return Verdict(credentials: d, dropPending: true)
            }
            return Verdict(credentials: p, dropPending: false)
        case (.some(let d), .none):
            return Verdict(credentials: d, dropPending: false)
        case (.none, .some(let p)):
            return Verdict(credentials: p, dropPending: false)
        case (.none, .none):
            return nil
        }
    }

    /// Returns the JWT `exp` (ms since epoch) of the id_token, or nil when
    /// the token is malformed or missing the claim. Used for freshness
    /// comparison only — never for an authz decision.
    private static func expiryMs(of auth: CodexAuth) -> Int64? {
        guard let date = JWT.expiry(auth.tokens.idToken) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
