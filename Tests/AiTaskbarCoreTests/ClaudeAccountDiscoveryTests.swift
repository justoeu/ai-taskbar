import Foundation
import Testing
@testable import AiTaskbarCore

/// `docs/SDD-claude-multi-account.md` §4, one test per rule.
@Suite("ClaudeAccountDiscovery")
struct ClaudeAccountDiscoveryTests {
    struct FakeProbe: ClaudeKeychainProbing {
        var items: [String: ClaudeKeychainPresence]
        func presence(service: String) -> ClaudeKeychainPresence { items[service] ?? .missing }
    }

    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    private func login(_ uuid: String) -> String {
        #"{"numStartups":3,"oauthAccount":{"accountUuid":"\#(uuid)","emailAddress":"x@example.com"}}"#
    }

    /// A non-default account folder under the temp home, logged in.
    @discardableResult
    private func makeFolder(_ name: String, uuid: String) throws -> URL {
        let dir = home.appendingPathComponent(name, isDirectory: true)
        try write(login(uuid), to: dir.appendingPathComponent(".claude.json"))
        return dir
    }

    private func service(_ dir: URL) -> String {
        ClaudeAccountDiscovery.keychainService(forConfigDir: dir.path)
    }

    private func discover(_ items: [String: ClaudeKeychainPresence],
                          environment: [String: String] = [:],
                          extraDirs: [String] = []) -> [ClaudeAccount] {
        ClaudeAccountDiscovery(home: home, environment: environment, extraDirs: extraDirs,
                               probe: FakeProbe(items: items)).discover()
    }

    private let present = ClaudeKeychainPresence.present(modified: nil)

    @Test("golden vector: the CLI's service name for a config folder")
    func golden_service_name() {
        // Fictitious path: the rule (SHA-256 of the absolute path, first 8
        // hex) was checked against the real CLI; the frozen value only has
        // to catch a change to it.
        let name = ClaudeAccountDiscovery.keychainService(forConfigDir: "/Users/example/.claude-work")
        #expect(name == "Claude Code-credentials-dd1118a7")
    }

    @Test("the service name hashes the path exactly as given")
    func service_name_shape() {
        let plain = ClaudeAccountDiscovery.keychainService(forConfigDir: "/Users/example/.claude-work")
        let slashed = ClaudeAccountDiscovery.keychainService(forConfigDir: "/Users/example/.claude-work/")
        #expect(slashed == "Claude Code-credentials-16c171f6")
        #expect(plain != slashed)
        let suffix = plain.dropFirst("Claude Code-credentials-".count)
        #expect(suffix.count == 8)
        #expect(suffix.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test("the default account keeps the legacy `anthropic` storage key")
    func default_account() throws {
        try write(login("uuid-a"), to: home.appendingPathComponent(".claude.json"))
        let accounts = discover([ClaudeAccountDiscovery.baseService: present])
        #expect(accounts.count == 1)
        let account = try #require(accounts.first)
        #expect(account.instanceKey.storageKey == "anthropic")
        #expect(account.label == nil)
        #expect(account.isDefault)
        #expect(account.keychainService == "Claude Code-credentials")
        #expect(account.projectsDir.path == home.appendingPathComponent(".claude/projects").path)
    }

    @Test("a config without a login is not an account")
    func default_without_login() throws {
        try write(#"{"numStartups":3}"#, to: home.appendingPathComponent(".claude.json"))
        #expect(discover([ClaudeAccountDiscovery.baseService: present]).isEmpty)
    }

    @Test("a login without its Keychain item is not an account")
    func default_without_item() throws {
        try write(login("uuid-a"), to: home.appendingPathComponent(".claude.json"))
        #expect(discover([:]).isEmpty)
    }

    @Test("an extra folder becomes an account with a hashed key and its folder label")
    func extra_account() throws {
        try write(login("uuid-a"), to: home.appendingPathComponent(".claude.json"))
        let work = try makeFolder(".claude-work", uuid: "uuid-b")
        let accounts = discover([ClaudeAccountDiscovery.baseService: present, service(work): present])
        #expect(accounts.count == 2)
        let extra = try #require(accounts.last)
        #expect(extra.label == "work")
        #expect(extra.keychainService == service(work))
        #expect(extra.instanceKey.storageKey == "anthropic." + ClaudeAccountDiscovery.shortHash("uuid-b"))
        #expect(extra.projectsDir.path == work.appendingPathComponent("projects").path)
    }

    @Test("orphaned Keychain items and backup folders without an item are ignored")
    func orphans_and_backups() throws {
        try write(login("uuid-a"), to: home.appendingPathComponent(".claude.json"))
        try makeFolder(".claude-backup-20260101000000", uuid: "uuid-a")
        let accounts = discover([
            ClaudeAccountDiscovery.baseService: present,
            "Claude Code-credentials-0ebee44f": present,   // no folder behind it
        ])
        #expect(accounts.map(\.instanceKey.storageKey) == ["anthropic"])
    }

    @Test("a folder logged into the default account collapses into the default")
    func dedupe_against_default() throws {
        try write(login("same"), to: home.appendingPathComponent(".claude.json"))
        let copy = try makeFolder(".claude-copy", uuid: "same")
        let accounts = discover([ClaudeAccountDiscovery.baseService: present, service(copy): present])
        #expect(accounts.count == 1)
        expectTrue(accounts.first?.isDefault ?? false)
    }

    @Test("two folders on one account keep the most recently written item")
    func dedupe_between_extras() throws {
        let old = try makeFolder(".claude-old", uuid: "same")
        let new = try makeFolder(".claude-new", uuid: "same")
        let accounts = discover([
            service(old): .present(modified: Date(timeIntervalSince1970: 1_000)),
            service(new): .present(modified: Date(timeIntervalSince1970: 2_000)),
        ])
        #expect(accounts.map(\.label) == ["new"])
    }

    @Test("accounts are ordered default first, then by label")
    func ordering() throws {
        try write(login("uuid-a"), to: home.appendingPathComponent(".claude.json"))
        let zeta = try makeFolder(".claude-zeta", uuid: "uuid-z")
        let alpha = try makeFolder(".claude-alpha", uuid: "uuid-y")
        let accounts = discover([ClaudeAccountDiscovery.baseService: present,
                                 service(zeta): present, service(alpha): present])
        #expect(accounts.map(\.label) == [nil, "alpha", "zeta"])
    }

    @Test("folder names: separator plus a safe suffix, never the config file")
    func folder_names() {
        for name in [".claude-work", ".claude_2", ".claude.personal", ".claude-a.b_c-1"] {
            #expect(ClaudeAccountDiscovery.isAccountFolderName(name), "\(name)")
        }
        for name in [".claude", ".claude.json", ".claude.json.bak-1790817156", ".claudeX",
                     ".claude-", ".claude-wörk", "claude-work", ".claude-a b"] {
            #expect(!ClaudeAccountDiscovery.isAccountFolderName(name), "\(name)")
        }
    }

    @Test("a symlinked folder is skipped: the CLI hashes the path it was given")
    func symlinked_folder() throws {
        let real = try makeFolder("elsewhere", uuid: "uuid-b")
        let link = home.appendingPathComponent(".claude-linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(discover([service(link): present, service(real): present]).isEmpty)
    }

    @Test("CLAUDE_CONFIG_DIR set with a trailing slash still finds its item")
    func env_with_trailing_slash() throws {
        let dir = try makeFolder("outside/acct", uuid: "uuid-c")
        let raw = dir.path + "/"
        let accounts = discover([ClaudeAccountDiscovery.keychainService(forConfigDir: raw): present],
                                environment: ["CLAUDE_CONFIG_DIR": raw])
        #expect(accounts.count == 1)
        #expect(accounts.first?.label == "acct")
        #expect(accounts.first?.configDir.path == dir.path)
    }

    @Test("config_dirs reaches a folder outside the home")
    func extra_dirs() throws {
        let dir = try makeFolder("outside/team", uuid: "uuid-d")
        let accounts = discover([service(dir): present], extraDirs: [dir.path])
        #expect(accounts.map(\.label) == ["team"])
    }

    @Test("a relative config_dirs entry is ignored")
    func relative_extra_dir() throws {
        #expect(discover([:], extraDirs: ["relative/path"]).isEmpty)
    }

    @Test("a directory where the config file should be is not a login")
    func config_file_not_regular() throws {
        let dir = home.appendingPathComponent(".claude-odd", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".claude.json"),
                                                withIntermediateDirectories: true)
        #expect(discover([service(dir): present]).isEmpty)
    }

    @Test("a rewritten config file is decoded again")
    func memo_invalidates_on_change() throws {
        let file = home.appendingPathComponent(".claude.json")
        try write(login("first"), to: file)
        #expect(ClaudeAccountDiscovery.accountUUID(at: file) == "first")
        try write(login("second-and-longer"), to: file)
        #expect(ClaudeAccountDiscovery.accountUUID(at: file) == "second-and-longer")
    }

    @Test("an unreadable default config keeps the default card (it needed only its item before)")
    func default_with_invalid_config() throws {
        try write("{ not json", to: home.appendingPathComponent(".claude.json"))
        let accounts = discover([ClaudeAccountDiscovery.baseService: present])
        #expect(accounts.map(\.instanceKey.storageKey) == ["anthropic"])
    }

    @Test("an unreadable extra config is skipped, not an account")
    func extra_with_invalid_config() throws {
        let dir = home.appendingPathComponent(".claude-broken", isDirectory: true)
        try write("{ not json", to: dir.appendingPathComponent(".claude.json"))
        #expect(discover([service(dir): present]).isEmpty)
    }

    @Test("a config read as invalid is not remembered: the next read sees the login")
    func invalid_config_is_retried() throws {
        let file = home.appendingPathComponent(".claude.json")
        try write("{ not json", to: file)
        #expect(ClaudeAccountDiscovery.login(at: file) == .unknown)
        try write(login("later"), to: file)
        #expect(ClaudeAccountDiscovery.login(at: file) == .loggedIn("later"))
    }

    @Test("a missing config or one with no login reads as logged out")
    func logged_out() throws {
        let file = home.appendingPathComponent(".claude.json")
        #expect(ClaudeAccountDiscovery.login(at: file) == .loggedOut)
        try write(#"{"numStartups":1}"#, to: file)
        #expect(ClaudeAccountDiscovery.login(at: file) == .loggedOut)
    }

    @Test("CLAUDE_CONFIG_DIR pointing at ~/.claude is not a second account")
    func env_is_default_folder() throws {
        try write(login("uuid-a"), to: home.appendingPathComponent(".claude.json"))
        let dir = home.appendingPathComponent(".claude", isDirectory: true)
        try write(login("uuid-z"), to: dir.appendingPathComponent(".claude.json"))
        let accounts = discover([ClaudeAccountDiscovery.baseService: present, service(dir): present],
                                environment: ["CLAUDE_CONFIG_DIR": dir.path])
        #expect(accounts.map(\.instanceKey.storageKey) == ["anthropic"])
    }

    @Test("two folders with the same label get distinct labels")
    func duplicate_labels() throws {
        let a = try makeFolder(".claude-work", uuid: "uuid-w1")
        let b = try makeFolder(".claude_work", uuid: "uuid-w2")
        let accounts = discover([service(a): present, service(b): present])
        #expect(accounts.compactMap(\.label) == ["work", "work 2"])
    }

    @Test("labels strip the .claude prefix and one separator")
    func labels() {
        let cases: [(String, String)] = [
            ("/h/.claude-work", "work"), ("/h/.claude_2", "2"), ("/h/.claude.personal", "personal"),
            ("/opt/team", "team"), ("/Volumes/work/.claude", "work"), ("/.claude", ".claude"),
        ]
        for (path, label) in cases {
            #expect(ClaudeAccountDiscovery.label(forConfigDir: URL(fileURLWithPath: path)) == label)
        }
    }
}

@Suite("ProviderInstanceKey")
struct ProviderInstanceKeyTests {
    @Test("the single instance keeps the bare vendor key")
    func legacy_key() {
        #expect(ProviderInstanceKey(vendor: .anthropic).storageKey == "anthropic")
        #expect(ProviderInstanceKey(vendor: .openai).storageKey == "openai")
    }

    @Test("an account appends after a dot and round-trips")
    func account_key() throws {
        let key = ProviderInstanceKey(vendor: .anthropic, account: "1a2b3c4d")
        #expect(key.storageKey == "anthropic.1a2b3c4d")
        #expect(ProviderInstanceKey(storageKey: key.storageKey) == key)
        #expect(ProviderInstanceKey(storageKey: "anthropic") == ProviderInstanceKey(vendor: .anthropic))
    }

    @Test("an unknown vendor or an empty account does not parse")
    func invalid_keys() {
        #expect(ProviderInstanceKey(storageKey: "nope.1") == nil)
        #expect(ProviderInstanceKey(storageKey: "anthropic.") == nil)
    }
}
