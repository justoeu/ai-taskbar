import Foundation
import CryptoKit
import os

/// One Claude Code login found on this Mac (`docs/SDD-claude-multi-account.md`).
public struct ClaudeAccount: Sendable, Equatable {
    public let instanceKey: ProviderInstanceKey
    /// nil for the default (`~/.claude`) account, which the UI names itself;
    /// otherwise the config folder's suffix (`.claude-work` → "work").
    public let label: String?
    public let configDir: URL
    public let keychainService: String
    public var isDefault: Bool { instanceKey.account == nil }

    public init(instanceKey: ProviderInstanceKey, label: String?, configDir: URL, keychainService: String) {
        self.instanceKey = instanceKey
        self.label = label
        self.configDir = configDir
        self.keychainService = keychainService
    }
    public var projectsDir: URL { configDir.appendingPathComponent("projects", isDirectory: true) }
}

/// Whether a Keychain item exists, read from its ATTRIBUTES only.
public enum ClaudeKeychainPresence: Sendable, Equatable {
    case missing
    case present(modified: Date?)
}

public protocol ClaudeKeychainProbing: Sendable {
    func presence(service: String) -> ClaudeKeychainPresence
}

/// Finds every Claude Code account from what the CLI itself writes, measured
/// on 2026-10-30 (SDD §2): one config folder per account — `~/.claude` (its
/// config file is `~/.claude.json`, OUTSIDE the folder) or a
/// `CLAUDE_CONFIG_DIR` folder (config file inside) — and one Keychain item
/// per folder, `Claude Code-credentials` for the default and
/// `Claude Code-credentials-<first 8 hex of SHA-256(folder path)>` otherwise.
///
/// A candidate becomes an account only with a logged-in config file AND its
/// Keychain item present, which drops the CLI's orphaned items (temporary
/// folders) and copied backup folders on its own. Nothing secret is read:
/// the probe asks for attributes and the config decode keeps `accountUuid`.
public struct ClaudeAccountDiscovery: Sendable {
    public static let baseService = "Claude Code-credentials"
    /// A larger config file is not a Claude Code config; never buffer it.
    static let maximumConfigBytes = 16 * 1024 * 1024

    private let home: URL
    private let environment: [String: String]
    private let extraDirs: [String]
    private let defaultService: String
    private let probe: any ClaudeKeychainProbing

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                extraDirs: [String] = [],
                defaultService: String = ClaudeAccountDiscovery.baseService,
                probe: any ClaudeKeychainProbing) {
        self.home = home
        self.environment = environment
        self.extraDirs = extraDirs
        self.defaultService = defaultService
        self.probe = probe
    }

    /// The default account first, then the others by label.
    public func discover() -> [ClaudeAccount] {
        var found: [(account: ClaudeAccount, uuid: String, modified: Date?)] = []
        for candidate in candidates() {
            let uuid: String
            switch Self.login(at: candidate.configFile) {
            case .loggedIn(let value):
                uuid = value
            case .loggedOut:
                continue
            case .unknown where candidate.isDefault:
                // The default card needed only its Keychain item before
                // multi-account; an unreadable or oversized `~/.claude.json`
                // must not take it away. Without the UUID it cannot be
                // deduped, so it gets a key no real UUID can collide with.
                uuid = "default:\(candidate.dir.path)"
            case .unknown:
                continue
            }
            var modified: Date?
            var service: String?
            for name in candidate.services {
                if case .present(let date) = probe.presence(service: name) {
                    service = name
                    modified = date
                    break
                }
            }
            guard let service else { continue }
            let key = candidate.isDefault
                ? ProviderInstanceKey(vendor: .anthropic)
                : ProviderInstanceKey(vendor: .anthropic, account: Self.shortHash(uuid))
            let account = ClaudeAccount(
                instanceKey: key,
                label: candidate.isDefault ? nil : Self.label(forConfigDir: candidate.dir),
                configDir: candidate.dir,
                keychainService: service)
            found.append((account, uuid, modified))
        }
        // One account per accountUuid: the default folder wins, then the most
        // recently written Keychain item, then the path, so the result is
        // deterministic.
        var byUUID: [String: (account: ClaudeAccount, uuid: String, modified: Date?)] = [:]
        for entry in found {
            guard let kept = byUUID[entry.uuid] else { byUUID[entry.uuid] = entry; continue }
            if Self.prefer(entry, over: kept) { byUUID[entry.uuid] = entry }
        }
        let sorted = byUUID.values.map(\.account).sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            let order = (a.label ?? "").localizedStandardCompare(b.label ?? "")
            if order != .orderedSame { return order == .orderedAscending }
            return a.configDir.path < b.configDir.path
        }
        return Self.disambiguatingLabels(sorted)
    }

    /// Labels name accounts in the switcher and in notifications, so two
    /// accounts must not share one (`.claude-work` and `.claude_work`, or the
    /// same folder name on two volumes): a repeat gets " 2", " 3"… in order.
    static func disambiguatingLabels(_ accounts: [ClaudeAccount]) -> [ClaudeAccount] {
        var used: Set<String> = []
        return accounts.map { account in
            guard let label = account.label else { return account }
            var unique = label
            var n = 2
            while !used.insert(unique.lowercased()).inserted {
                unique = "\(label) \(n)"
                n += 1
            }
            guard unique != label else { return account }
            return ClaudeAccount(instanceKey: account.instanceKey, label: unique,
                                 configDir: account.configDir, keychainService: account.keychainService)
        }
    }

    private static func prefer(_ a: (account: ClaudeAccount, uuid: String, modified: Date?),
                               over b: (account: ClaudeAccount, uuid: String, modified: Date?)) -> Bool {
        if a.account.isDefault != b.account.isDefault { return a.account.isDefault }
        let ma = a.modified ?? .distantPast
        let mb = b.modified ?? .distantPast
        if ma != mb { return ma > mb }
        return a.account.configDir.path < b.account.configDir.path
    }

    // MARK: - Candidates

    struct Candidate: Equatable {
        let dir: URL
        let configFile: URL
        /// Keychain service names to try, in order.
        let services: [String]
        let isDefault: Bool
    }

    func candidates() -> [Candidate] {
        var out: [Candidate] = [Candidate(
            dir: home.appendingPathComponent(".claude", isDirectory: true),
            configFile: home.appendingPathComponent(".claude.json"),
            services: [defaultService],
            isDefault: true)]
        var paths: [String] = []
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: home.path)
        } catch {
            AppLog.keychain.error(
                "Claude account discovery: cannot list the home folder: \(error.localizedDescription, privacy: .public)")
            names = []
        }
        for name in names.sorted() where Self.isAccountFolderName(name) {
            let url = home.appendingPathComponent(name, isDirectory: true)
            // `.isDirectoryKey` does not follow a symlink, so a linked
            // folder is skipped: the CLI hashes the path it was given,
            // which a link would not reproduce.
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            paths.append(url.path)
        }
        if let env = environment["CLAUDE_CONFIG_DIR"], !env.isEmpty { paths.append(env) }
        paths.append(contentsOf: extraDirs)

        // `CLAUDE_CONFIG_DIR=~/.claude` would make the default folder a
        // second account scanning the same `projects/`.
        var seen: Set<String> = [out[0].dir.path]
        for raw in paths {
            let expanded = (raw as NSString).expandingTildeInPath
            let trimmed = Self.trimmingTrailingSlashes(expanded)
            guard trimmed.hasPrefix("/"), seen.insert(trimmed).inserted else { continue }
            var services = [Self.keychainService(forConfigDir: trimmed)]
            for variant in [expanded, trimmed + "/"] {
                let name = Self.keychainService(forConfigDir: variant)
                if !services.contains(name) { services.append(name) }
            }
            let dir = URL(fileURLWithPath: trimmed, isDirectory: true)
            out.append(Candidate(dir: dir,
                                 configFile: dir.appendingPathComponent(".claude.json"),
                                 services: services,
                                 isDefault: false))
        }
        return out
    }

    /// `.claude-work`, `.claude_2`, `.claude.personal`: the default folder's
    /// name plus a separator and a suffix. `.claude.json` and its backups
    /// match the shape but are files, and are excluded by name as well.
    static func isAccountFolderName(_ name: String) -> Bool {
        guard name.hasPrefix(".claude"), !name.hasPrefix(".claude.json") else { return false }
        let rest = name.dropFirst(".claude".count)
        guard let separator = rest.first, "-_.".contains(separator) else { return false }
        let suffix = rest.dropFirst()
        guard !suffix.isEmpty else { return false }
        return suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    // MARK: - Naming

    /// The Keychain service the Claude Code CLI uses for a non-default
    /// config folder: the first 8 hex of SHA-256 over the folder's absolute
    /// path, as given (no trailing slash added or removed).
    public static func keychainService(forConfigDir path: String) -> String {
        "\(baseService)-\(shortHash(path))"
    }

    /// First 8 hex characters of SHA-256 over the UTF-8 bytes.
    static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func label(forConfigDir dir: URL) -> String {
        let name = dir.lastPathComponent
        // `/Volumes/work/.claude` is named by the folder that holds it.
        if name == ".claude" {
            let parent = dir.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty || parent == "/" ? name : parent
        }
        guard name.hasPrefix(".claude") else { return name }
        var rest = Substring(name.dropFirst(".claude".count))
        if let first = rest.first, "-_.".contains(first) { rest = rest.dropFirst() }
        return rest.isEmpty ? name : String(rest)
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    // MARK: - Config file

    private struct ConfigFile: Decodable {
        let oauthAccount: OAuthAccount?
        struct OAuthAccount: Decodable {
            let accountUuid: String?
        }
    }

    /// What a config file says about its login.
    enum Login: Sendable, Equatable {
        case loggedIn(String)
        /// Missing file, or valid JSON with no `oauthAccount.accountUuid`.
        case loggedOut
        /// Exists but could not be read: not a regular file, oversized,
        /// unreadable, or not valid JSON (e.g. read mid-rewrite). Never
        /// remembered, so the next discovery reads it again.
        case unknown
    }

    private struct MemoEntry: Sendable {
        let size: Int
        let modified: Date
        let login: Login
    }

    /// `~/.claude.json` is a large, frequently rewritten file and discovery
    /// re-runs on every popover open: decode it again only when it changed.
    private static let memo = OSAllocatedUnfairLock<[String: MemoEntry]>(initialState: [:])

    /// The logged-in account's UUID, or nil for any other answer.
    static func accountUUID(at configFile: URL) -> String? {
        if case .loggedIn(let uuid) = login(at: configFile) { return uuid }
        return nil
    }

    static func login(at configFile: URL) -> Login {
        let resolved = configFile.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try resolved.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        } catch {
            if FileAbsence.isAbsence(error) { return .loggedOut }
            logUnreadable(configFile, error.localizedDescription)
            return .unknown
        }
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumConfigBytes,
              let modified = values.contentModificationDate else {
            logUnreadable(configFile, "not a regular file of at most \(maximumConfigBytes) bytes")
            return .unknown
        }
        let path = configFile.path
        if let hit = memo.withLock({ $0[path] }), hit.size == size, hit.modified == modified {
            return hit.login
        }
        let data: Data
        do {
            data = try Data(contentsOf: resolved)
        } catch {
            if FileAbsence.isAbsence(error) { return .loggedOut }
            logUnreadable(configFile, error.localizedDescription)
            return .unknown
        }
        let decoded: ConfigFile
        do {
            decoded = try JSONDecoder().decode(ConfigFile.self, from: data)
        } catch {
            logUnreadable(configFile, "not valid JSON")
            return .unknown
        }
        let login: Login
        if let value = decoded.oauthAccount?.accountUuid, !value.isEmpty {
            login = .loggedIn(value)
        } else {
            login = .loggedOut
        }
        memo.withLock { $0[path] = MemoEntry(size: size, modified: modified, login: login) }
        return login
    }

    private static func logUnreadable(_ file: URL, _ reason: String) {
        AppLog.keychain.error(
            "Claude account discovery: cannot read \(file.path, privacy: .public): \(reason, privacy: .public)")
    }
}
