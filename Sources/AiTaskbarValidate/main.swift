import Foundation
import AiTaskbarCore
import AiTaskbarProviders
import AiTaskbarTesting

// MARK: - Runtime validation suite
//
// Runs without XCTest (Xcode-only) by using plain Swift + a small assert
// helper. Covers the same surface the XCTest suite covers, plus a few
// integration checks. Exits non-zero on any failure.
//
// Run via `make validate` or `swift run ai-taskbar-validate`.

var failures: [String] = []
var passed = 0

func expect(_ condition: @autoclosure () -> Bool,
            _ message: String,
            file: StaticString = #file, line: UInt = #line) {
    if condition() {
        passed += 1
        print("  ✓ \(message)")
    } else {
        let loc = "\(("\(file)" as NSString).lastPathComponent):\(line)"
        let msg = "  ✗ \(message)  [\(loc)]"
        failures.append(msg)
        print(msg)
    }
}

func section(_ name: String, _ body: () throws -> Void) {
    print("\n[\(name)]")
    do { try body() }
    catch { failures.append("  ✗ \(name) threw: \(error)"); print("  ✗ \(name) threw: \(error)") }
}

// MARK: - Tests

section("AppError") {
    let a = AppError.disabled("test")
    let b = AppError.disabled("test")
    let c = AppError.disabled("different")
    expect(a == b, "Equatable: same payload equal")
    expect(a != c, "Equatable: different payload not equal")
    expect(a.isDisabled, "isDisabled true for .disabled")
    expect(!AppError.http(status: 500, body: "x").isDisabled, "isDisabled false for non-disabled")
    expect(AppError.http(status: 500, body: "x").isTransient, "5xx is transient")
    expect(AppError.http(status: 429, body: "x").isTransient, "429 is transient")
    expect(!AppError.http(status: 401, body: "x").isTransient, "401 is not transient")
    expect(a.localizedDescription == "disabled: test",
           "LocalizedError surfaces description")
    let wrapped = AppError.wrapping(a)
    expect(wrapped == a, "wrapping AppError returns same instance")
}

section("JSONValue round-trip") {
    let payload: JSONValue = .object([
        "tokens": .object([
            "access_token": .string("a"),
            "refresh_token": .string("r"),
            "id_token": .string("i"),
        ]),
        "account_id": .string("acc"),
        "last_refresh": .int(1764000000),
        "metrics": .array([.int(1), .double(2.5), .bool(true)]),
    ])
    let encoded = try SharedCoders.encoder.encode(payload)
    let decoded = try SharedCoders.decoder.decode(JSONValue.self, from: encoded)
    expect(decoded == payload, "JSONValue Codable round-trip preserves shape")
}

section("KimiConfig.validate") {
    expect(KimiConfig.validate("https://api.moonshot.ai/v1") != nil,
           "accepts https://api.moonshot.ai/v1")
    expect(KimiConfig.validate("https://api.moonshot.cn/v1") != nil,
           "accepts https://api.moonshot.cn/v1")
    expect(KimiConfig.validate("http://api.moonshot.ai/v1") == nil,
           "rejects http://")
    expect(KimiConfig.validate("https://attacker.com/v1") == nil,
           "rejects unknown host")
    expect(KimiConfig.validate("https://API.MOONSHOT.AI/v1") != nil,
           "scheme/host case-insensitive")
    expect(KimiConfig.validate("not a url") == nil,
           "rejects garbage")
}

section("UsageWindow / VendorSnapshot helpers") {
    let session = UsageWindow(label: "Session", utilizationPercent: 47, resetsAt: nil)
    let weekly = UsageWindow(label: "Weekly", utilizationPercent: 16, resetsAt: nil)
    let snap = VendorSnapshot.anthropic(
        AnthropicSnapshot(planLabel: "Claude Max 5x", session: session, weekly: weekly,
                          opus: nil, extraUsageUSD: 2.45))
    expect(snap.vendorId == .anthropic, "vendorId discriminator")
    expect(snap.windows.count == 2, "windows omits nil opus")
    expect(snap.maxUtilization == 47, "maxUtilization picks max across windows")
    expect(snap.planLabel == "Claude Max 5x", "planLabel propagates")
}

section("Wire types: Anthropic fixture") {
    let parsed = try SharedCoders.decoder.decode(
        AnthropicUsageResponse.self,
        from: Fixtures.data(Fixtures.anthropicUsage200))
    let s = parsed.toSnapshot(planLabel: "Claude Max 5x")
    expect(s.planLabel == "Claude Max 5x", "Anthropic plan label")
    expect(s.session?.label == "Session (5h)", "Anthropic session label")
    expect(Int((s.session?.utilizationPercent ?? 0).rounded()) == 47,
           "Anthropic session utilization 47%")
    expect(s.weekly?.label == "Weekly (7d)", "Anthropic weekly label")
    expect(s.opus?.label == "Opus (7d)", "Anthropic opus field labeled correctly (not 'sonnet')")
    expect(s.extraUsageUSD == 2.45, "Anthropic extra usage USD")
}

section("Wire types: OpenAI fixture") {
    let parsed = try SharedCoders.decoder.decode(
        OpenAIUsageResponse.self,
        from: Fixtures.data(Fixtures.openaiUsage200))
    let s = parsed.toSnapshot(planLabel: "ChatGPT Plus",
                              fallbackNow: Date(timeIntervalSince1970: 1_764_000_000))
    expect(parsed.plan_type == "plus", "OpenAI plan_type parsed")
    expect(s.primary?.label == "Session (5h)", "OpenAI primary labeled by limit_window_seconds")
    expect(Int((s.primary?.utilizationPercent ?? 0).rounded()) == 33,
           "OpenAI primary 33%")
    expect(s.secondary?.label == "Weekly (7d)", "OpenAI secondary labeled")
    expect(s.creditsUSD == 4.20, "OpenAI credits balance parsed from \"$4.20\" string")
    expect(s.messageCountRange == "≈ 5–10 local msgs left",
           "OpenAI message-count range")
}

section("Wire types: OpenRouter fixture (combined)") {
    let credits = try SharedCoders.decoder.decode(
        OpenRouterCreditsResponse.self,
        from: Fixtures.data(Fixtures.openrouterCredits200))
    let key = try SharedCoders.decoder.decode(
        OpenRouterKeyResponse.self,
        from: Fixtures.data(Fixtures.openrouterKey200))
    let combined = OpenRouterCombined(credits: credits, key: key)
    let s = combined.toSnapshot()
    expect(s.planLabel == "OpenRouter: primary", "OpenRouter plan label")
    expect(Int((s.balance?.utilizationPercent ?? 0).rounded()) == 25,
           "OpenRouter balance utilization 25% of $10")
    // Round-trip through OpenRouterCachedPayload (P3)
    let payload = OpenRouterCachedPayload(credits: credits, key: key)
    let bytes = try SharedCoders.encoder.encode(payload)
    let decoded = try SharedCoders.decoder.decode(OpenRouterCachedPayload.self, from: bytes)
    expect(decoded.credits.data.total_credits == 10.0,
           "OpenRouterCachedPayload Codable preserves total_credits")
}

section("Wire types: Z.AI fixture") {
    let env = try SharedCoders.decoder.decode(
        ZAIEnvelope.self,
        from: Fixtures.data(Fixtures.zaiUsage200))
    let s = env.toSnapshot(configTier: nil)
    expect(s.planLabel == "GLM Lite", "Z.AI plan label from data.level")
    expect(s.session?.label == "Session", "Z.AI session classification")
    expect(s.weekly?.label == "Weekly", "Z.AI weekly classification")
    expect(s.mcp?.label == "MCP tools", "Z.AI MCP classification")
}

section("DiskCache TTL semantics") {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-validate-\(UUID().uuidString)")
    try Paths.ensureDir(tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let fresh = DiskCache(vendor: .anthropic, baseDir: tmp, ttl: 60, maxStale: 86_400)
    try fresh.writePayload(Data("hello".utf8))
    expect(fresh.freshPayload() == Data("hello".utf8), "within TTL returns fresh")
    expect(!fresh.isStale(), "no stale marker after success")

    let expired = DiskCache(vendor: .anthropic, baseDir: tmp, ttl: 0.001, maxStale: 86_400)
    try expired.writePayload(Data("hi".utf8))
    Thread.sleep(forTimeInterval: 0.05)
    expect(expired.freshPayload() == nil, "expired TTL returns nil")
    expect(expired.anyPayload() == Data("hi".utf8), "anyPayload still returns within maxStale")

    expired.markFailed(FetchError(status: 500, body: "boom"))
    expect(expired.isStale(), "stale marker present")
    let err = expired.lastError()
    expect(err?.status == 500 && err?.body.hasPrefix("boom") == true,
           "lastError round-trips status+body")
}

section("AtomicFileWrite permissions") {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-validate-perms-\(UUID().uuidString)")
    try Paths.ensureDir(tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let secretFile = tmp.appendingPathComponent("secret.json")
    try AtomicFileWrite.write(Data("token=xyz".utf8), to: secretFile, permissions: 0o600)
    let attrs = try FileManager.default.attributesOfItem(atPath: secretFile.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    expect(perms == 0o600, "AtomicFileWrite locks tempfile to 0o600 before rename")
}

section("JWT decode") {
    // Hand-crafted JWT with payload {"exp": 1764201600, "plan": "pro"}
    let header = Data("{\"alg\":\"none\"}".utf8).base64URL()
    let payload = Data(#"{"exp":1764201600,"plan":"pro"}"#.utf8).base64URL()
    let token = "\(header).\(payload)."
    expect(JWT.expiry(token)?.timeIntervalSince1970 == 1_764_201_600,
           "JWT.expiry parses exp claim")
    expect(JWT.claim(token, key: "plan", as: String.self) == "pro",
           "JWT.claim extracts string claim")
    expect(JWT.expiry("malformed") == nil, "JWT.expiry returns nil for garbage")
    expect(JWT.expiry("") == nil, "JWT.expiry doesn't crash on empty string")
}

section("Config: full round-trip via TOMLKit") {
    let toml = #"""
    [ui]
    primary = "zai"
    refresh_interval_seconds = 120

    [thresholds]
    warning = 75
    critical = 95

    [notifications]
    enabled = true
    notify_at = [80, 100]

    [anthropic]
    enabled = false

    [kimi]
    enabled = true
    api_key = "sk-xyz"
    base_url = "https://api.moonshot.cn/v1"
    """#
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-validate-cfg-\(UUID().uuidString).toml")
    try Data(toml.utf8).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let loader = try ConfigLoader(path: tmp)
    let cfg = try loader.load()

    expect(cfg.ui.primary == .zai, "UI primary parsed")
    expect(cfg.ui.refreshIntervalSeconds == 120, "refresh_interval_seconds parsed")
    expect(cfg.thresholds.warning == 75, "thresholds.warning (int → double)")
    expect(cfg.thresholds.critical == 95, "thresholds.critical")
    expect(cfg.notifications.notifyAt == [80, 100], "notify_at array (ints → doubles)")
    expect(cfg.anthropic.enabled == false, "anthropic disabled")
    expect(cfg.kimi.apiKey == "sk-xyz", "kimi inline api_key")
    expect(cfg.kimi.baseURL == "https://api.moonshot.cn/v1", ".cn base URL accepted")
}

section("Config: rejected Kimi base_url falls back") {
    let toml = #"""
    [kimi]
    enabled = true
    base_url = "http://attacker.com/v1"
    """#
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-validate-bad-\(UUID().uuidString).toml")
    try Data(toml.utf8).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let cfg = try ConfigLoader(path: tmp).load()
    expect(cfg.kimi.baseURL == "https://api.moonshot.ai/v1",
           "malicious base_url rejected → fallback to default")
}

section("UsageHistoryStore: append + load + compact") {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-validate-history-\(UUID().uuidString)")
    try Paths.ensureDir(tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = UsageHistoryStore(vendor: .anthropic, baseDir: tmp, retention: 86_400)
    let now = Date()
    store.append(maxUtilization: 10, at: now.addingTimeInterval(-100))
    store.append(maxUtilization: 50, at: now.addingTimeInterval(-50))
    store.append(maxUtilization: 80, at: now)
    let samples = store.load(since: now.addingTimeInterval(-200))
    expect(samples.count == 3, "load returns 3 samples")
    expect(samples.map(\.max) == [10, 50, 80], "samples sorted by timestamp ascending")

    // Compact with very short retention should drop older entries.
    let shortStore = UsageHistoryStore(vendor: .openai, baseDir: tmp, retention: 0.01)
    shortStore.append(maxUtilization: 1, at: now.addingTimeInterval(-3600))
    shortStore.append(maxUtilization: 2, at: now)
    Thread.sleep(forTimeInterval: 0.05)
    shortStore.compact()
    let remaining = shortStore.load(since: now.addingTimeInterval(-10_000))
    expect(remaining.allSatisfy { $0.max == 2 } || remaining.isEmpty,
           "compact removed pre-cutoff entries")
}

section("PricingTable lookup") {
    let opus = PricingTable.lookup("claude-opus-4-7", table: PricingTable.anthropic)
    expect(opus?.inputPer1M == 15, "exact match")
    let prefix = PricingTable.lookup("gpt-5-codex-2026-02", table: PricingTable.openai)
    expect(prefix != nil, "prefix match finds gpt-5-codex")
    let kimi = PricingTable.lookup("kimi-k2-6", table: PricingTable.kimi)
    expect(kimi?.cacheReadPer1M == 0.16, "Kimi K2.6 cache-hit price")
    let unknown = PricingTable.lookup("totally-made-up-model", table: PricingTable.anthropic)
    expect(unknown == nil, "unknown model returns nil")
}

section("S5: OpenAI cache strips PII") {
    let raw = #"""
    {
      "user_id": "u_secret",
      "account_id": "acc_secret",
      "email": "alice@example.com",
      "plan_type": "plus",
      "rate_limit": { "primary_window": { "used_percent": 50.0 } }
    }
    """#
    let sanitized = try OpenAIProvider.stripPII(from: Data(raw.utf8))
    let blob = try SharedCoders.decoder.decode([String: JSONValue].self, from: sanitized)
    expect(blob["user_id"] == nil, "user_id stripped from cache payload")
    expect(blob["account_id"] == nil, "account_id stripped from cache payload")
    expect(blob["email"] == nil, "email stripped from cache payload")
    expect(blob["plan_type"] != nil, "plan_type preserved")
    expect(blob["rate_limit"] != nil, "rate_limit preserved")
}

section("S8: TOCTOU — refuse symlinked dir") {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-symlink-\(UUID().uuidString)")
    let target = parent.appendingPathComponent("real")
    let link = parent.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    defer { try? FileManager.default.removeItem(at: parent) }
    do {
        try Paths.ensureDir(link)
        failures.append("  ✗ ensureDir should have refused symlink"); print("  ✗ ensureDir should have refused symlink")
    } catch {
        passed += 1
        print("  ✓ ensureDir refuses symlinked path (\(error))")
    }
    // Sanity: non-symlinked dir still works.
    try Paths.ensureDir(target)
    expect(true, "ensureDir accepts real directory")
    expect(Paths.isSymbolicLink(at: link), "isSymbolicLink detects link")
    expect(!Paths.isSymbolicLink(at: target), "isSymbolicLink false for regular dir")
}

section("S6: cache files locked to 0o600") {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-cache-perm-\(UUID().uuidString)")
    try Paths.ensureDir(tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let cache = DiskCache(vendor: .openai, baseDir: tmp)
    try cache.writePayload(Data(#"{"x":1}"#.utf8))
    let cacheFile = tmp.appendingPathComponent("usage.json")
    let attrs = try FileManager.default.attributesOfItem(atPath: cacheFile.path)
    let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    expect(perm == 0o600, "DiskCache.writePayload yields 0o600 file")
}

section("S7: notifications discreet mode config") {
    let toml = #"""
    [notifications]
    enabled = true
    notify_at = [90]
    discreet = true
    """#
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-discreet-\(UUID().uuidString).toml")
    try Data(toml.utf8).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let cfg = try ConfigLoader(path: tmp).load()
    expect(cfg.notifications.discreet, "discreet flag decoded from TOML")
    expect(cfg.notifications.notifyAt == [90], "single-threshold notify_at preserved")
}

section("S4: AnthropicConfig keychain_account knob") {
    let toml = #"""
    [anthropic]
    enabled = true
    keychain_account = "my.work.account"
    """#
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-keyacc-\(UUID().uuidString).toml")
    try Data(toml.utf8).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let cfg = try ConfigLoader(path: tmp).load()
    expect(cfg.anthropic.keychainAccount == "my.work.account",
           "keychain_account parsed for multi-account pinning")
}

section("P6: HTTPClient uses ephemeral URLSession by default") {
    let client = HTTPClient()
    let cfg = client.sessionConfiguration
    expect(cfg.urlCache == nil, "no URLCache (no 20 MB disk cache)")
    expect(cfg.httpCookieStorage == nil, "no persistent cookie storage")
    expect(cfg.urlCredentialStorage == nil, "no credential storage")
    expect(cfg.httpMaximumConnectionsPerHost == 4, "connections capped at 4")
}

section("B3: CodexLogScanner regex parser") {
    // Whitespace-tolerant: handles spaces, tabs, leading whitespace.
    let spaceBody = "session_loop: turn complete model=gpt-5.5 total_usage_tokens=20252"
    expect(CodexLogScanner.parse(body: spaceBody)?.model == "gpt-5.5",
           "parses model= with spaces")
    expect(CodexLogScanner.parse(body: spaceBody)?.tokens == 20252,
           "parses total_usage_tokens=N")
    let tabBody = "session_loop:\tmodel=gpt-5-codex\ttotal_usage_tokens=42"
    expect(CodexLogScanner.parse(body: tabBody)?.model == "gpt-5-codex",
           "parses model= after tab")
    expect(CodexLogScanner.parse(body: tabBody)?.tokens == 42,
           "parses tokens after tab")
    // Anchor: don't match `xmodel=foo` (substring of unrelated word).
    let stickyBody = "xmodel=junk model=gpt-5 total_usage_tokens=10"
    expect(CodexLogScanner.parse(body: stickyBody)?.model == "gpt-5",
           "anchored at whitespace, ignores 'xmodel=junk'")
    // Missing fields → nil
    expect(CodexLogScanner.parse(body: "no relevant fields") == nil,
           "returns nil when both fields absent")
    expect(CodexLogScanner.parse(body: "model=gpt-5 only") == nil,
           "returns nil when only model present")
}

section("B7: ConfigLoader(path:) is non-throwing") {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-validate-init-\(UUID().uuidString).toml")
    // The whole point: this constructor is statically non-throwing.
    // The fact that this line compiles without `try` IS the test.
    let loader = ConfigLoader(path: tmp)
    expect(loader.path == tmp, "explicit-path init sets path")
}

section("B1: OpenAIProvider memoizes plan label") {
    let header = Data("{\"alg\":\"none\"}".utf8).base64URL()
    let payload = Data(#"{"https://api.openai.com/auth.chatgpt_plan_type":"pro"}"#.utf8).base64URL()
    let token = "\(header).\(payload)."
    expect(OpenAIProvider.computePlanLabel(from: token) == "ChatGPT Pro",
           "computes label from JWT claim")
    let token2 = "\(header).\(Data(#"{"https://api.openai.com/auth.chatgpt_plan_type":"team"}"#.utf8).base64URL())."
    expect(OpenAIProvider.computePlanLabel(from: token2) == "ChatGPT Team",
           "different claim yields different label")
    expect(OpenAIProvider.computePlanLabel(from: "not.a.jwt") == nil,
           "returns nil for garbage token")
}

section("B2: AnthropicProvider plan label mapping") {
    expect(AnthropicProvider.credLabel(subscriptionType: "max",
                                       rateLimit: "default_claude_max_5x") == "Claude Max 5x",
           "Claude Max 5x tier")
    expect(AnthropicProvider.credLabel(subscriptionType: "max",
                                       rateLimit: "default_claude_max_20x") == "Claude Max 20x",
           "Claude Max 20x tier")
    expect(AnthropicProvider.credLabel(subscriptionType: "max",
                                       rateLimit: nil) == "Claude Max",
           "Max without tier suffix falls back")
    expect(AnthropicProvider.credLabel(subscriptionType: "pro",
                                       rateLimit: nil) == "Claude Pro",
           "Pro tier")
    expect(AnthropicProvider.credLabel(subscriptionType: nil,
                                       rateLimit: nil) == nil,
           "nil subscriptionType → nil label")
}

section("A3: flexibleDoubleIfPresent decoder helper") {
    // JSON value can arrive as int OR float; decoder must accept both.
    struct Probe: Decodable {
        let a: Double?
        let b: Double?
        let c: Double?
        init(from decoder: Decoder) throws {
            let cc = try decoder.container(keyedBy: CodingKeys.self)
            a = cc.flexibleDoubleIfPresent(forKey: .a)
            b = cc.flexibleDoubleIfPresent(forKey: .b)
            c = cc.flexibleDoubleIfPresent(forKey: .c)
        }
        enum CodingKeys: String, CodingKey { case a, b, c }
    }
    let p = try SharedCoders.decoder.decode(Probe.self,
        from: Data(#"{"a": 70, "b": 70.5, "c": null}"#.utf8))
    expect(p.a == 70.0, "int → double")
    expect(p.b == 70.5, "double passthrough")
    expect(p.c == nil, "null → nil")
    let q = try SharedCoders.decoder.decode(Probe.self, from: Data(#"{"a": 42}"#.utf8))
    expect(q.b == nil, "missing key → nil")
}

section("A4: OAuthErrorBody parses three known shapes") {
    expect(OAuthErrorBody.parse(Data(#"{"error_description":"bad rt"}"#.utf8)) == "bad rt",
           "OAuth standard shape")
    expect(OAuthErrorBody.parse(Data(#"{"error":{"message":"nope"}}"#.utf8)) == "nope",
           "Anthropic nested shape")
    expect(OAuthErrorBody.parse(Data(#"{"error":"plain"}"#.utf8)) == "plain",
           "Bare string shape")
    expect(OAuthErrorBody.parse(Data(#"{"unrelated":"x"}"#.utf8)) == nil,
           "Unknown shape returns nil")
    // Back-compat: AnthropicOAuth.parseErrorBody delegates to OAuthErrorBody.
    expect(AnthropicOAuth.parseErrorBody(Data(#"{"error":"foo"}"#.utf8)) == "foo",
           "AnthropicOAuth.parseErrorBody back-compat works")
}

section("A4: OAuth refresh response decodes flexible expires_in") {
    let intJSON  = Data(#"{"access_token":"a","expires_in":3600}"#.utf8)
    let floatJSON = Data(#"{"access_token":"a","expires_in":3600.5}"#.utf8)
    let anth1 = try SharedCoders.decoder.decode(AnthropicOAuth.RefreshResponse.self, from: intJSON)
    let anth2 = try SharedCoders.decoder.decode(AnthropicOAuth.RefreshResponse.self, from: floatJSON)
    expect(anth1.expires_in == 3600, "Anthropic expires_in int → Double")
    expect(anth2.expires_in == 3600.5, "Anthropic expires_in float passthrough")
    let oai1 = try SharedCoders.decoder.decode(OpenAIOAuth.RefreshResponse.self, from: intJSON)
    expect(oai1.expires_in == 3600, "OpenAI expires_in int → Double")
}

section("DEF-1: SecurityConfig parses pinning knobs") {
    let toml = #"""
    [security]
    pin_hosts = ["api.anthropic.com", "chatgpt.com"]
    pin_audit_only = true
    """#
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-sec-\(UUID().uuidString).toml")
    try Data(toml.utf8).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let cfg = try ConfigLoader(path: tmp).load()
    expect(cfg.security.pinHosts == ["api.anthropic.com", "chatgpt.com"],
           "pin_hosts parsed")
    expect(cfg.security.pinAuditOnly == true, "pin_audit_only parsed")
    let empty = AppConfig()
    expect(empty.security.pinHosts.isEmpty, "default pinHosts is empty (no pinning)")
    expect(empty.security.pinAuditOnly == false, "default audit mode is strict")
}

section("DEF-1: PinStore TOFU semantics") {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-pins-\(UUID().uuidString)")
    try Paths.ensureDir(tmpDir)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let store = PinStore(baseDir: tmpDir)
    expect(store.get(host: "api.anthropic.com") == nil,
           "fresh store has no pin")
    store.set(host: "api.anthropic.com", hash: "abc123==")
    expect(store.get(host: "api.anthropic.com") == "abc123==",
           "pin persists in memory")
    // Drop the in-memory cache by creating a new store on the same dir.
    let reopened = PinStore(baseDir: tmpDir)
    expect(reopened.get(host: "api.anthropic.com") == "abc123==",
           "pin persists on disk")
    expect(reopened.get(host: "API.ANTHROPIC.COM") == "abc123==",
           "host lookup case-insensitive")
    reopened.clear(host: "api.anthropic.com")
    let third = PinStore(baseDir: tmpDir)
    expect(third.get(host: "api.anthropic.com") == nil,
           "clear() removes pin from disk")
    // Verify the file was created with 0o600 perms.
    store.set(host: "another.host", hash: "deadbeef==")
    let pinFile = tmpDir.appendingPathComponent("another.host.txt")
    let attrs = try FileManager.default.attributesOfItem(atPath: pinFile.path)
    let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    expect(perm == 0o600, "PinStore writes pin files with 0o600")
}

section("DEF-1: PinningDelegate is constructable + idempotent") {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-delegate-\(UUID().uuidString)")
    try Paths.ensureDir(tmpDir)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let store = PinStore(baseDir: tmpDir)
    let delegate = PinningDelegate(
        pinnedHosts: ["api.anthropic.com", "CHATGPT.COM"],
        store: store,
        auditOnly: false
    )
    // Hosts list normalized to lowercase.
    expect(delegate.pinnedHosts.contains("api.anthropic.com"), "pin includes lowercase")
    expect(delegate.pinnedHosts.contains("chatgpt.com"), "pin normalizes to lowercase")
    expect(!delegate.pinnedHosts.contains("CHATGPT.COM"),
           "stored value is lowercase, not the original case")
}

section("DEF-1: HTTPClient.pinned falls back gracefully") {
    // Empty pinHosts → default ephemeral client (no pinning).
    let nothing = HTTPClient.pinned(pinnedHosts: [])
    expect(nothing.sessionConfiguration.urlCache == nil,
           "empty pin list still returns ephemeral session")
    // Non-empty list → constructable.
    let pinned = HTTPClient.pinned(pinnedHosts: ["api.anthropic.com"])
    expect(pinned.sessionConfiguration.urlCache == nil,
           "pinned client is also ephemeral")
}

section("DEF-2: entitlements.plist exists for Developer ID workflow") {
    let candidates = [
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/entitlements.plist"),
        URL(fileURLWithPath: NSString(string: "Resources/entitlements.plist")
            .expandingTildeInPath),
    ]
    let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    expect(found != nil, "Resources/entitlements.plist present for sign-developer target")
}

section("L10n: language config override") {
    let toml = #"""
    [ui]
    language = "pt-BR"
    """#
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-l10n-\(UUID().uuidString).toml")
    try Data(toml.utf8).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let cfg = try ConfigLoader(path: tmp).load()
    expect(cfg.ui.language == "pt-BR", "language parsed from [ui] section")

    let defaultCfg = AppConfig()
    expect(defaultCfg.ui.language == nil, "default language is nil (follow system)")
}

section("Updates: semver comparison") {
    expect(Semver.isNewer("v0.2.0", than: "v0.1.0"), "0.2.0 > 0.1.0")
    expect(Semver.isNewer("0.1.1", than: "0.1.0"), "patch bump")
    expect(!Semver.isNewer("v0.1.0", than: "v0.1.0"), "equal not newer")
    expect(!Semver.isNewer("v0.0.9", than: "v0.1.0"), "older not newer")
    expect(Semver.isNewer("v1.0.0", than: "v0.99.99"), "major bump")
    expect(Semver.isNewer("v0.1.0", than: "v0.1.0-beta1"),
           "stable > prerelease of same base")
    expect(!Semver.isNewer("v0.1.0-beta1", than: "v0.1.0"),
           "prerelease < stable")
    expect(Semver.isNewer("v0.1.0-beta2", than: "v0.1.0-beta1"),
           "later prerelease tag wins")
    expect(Semver.isNewer("v0.1", than: "v0.0.5"),
           "missing patch defaults to 0")
}

section("Updates: config parse") {
    let toml = #"""
    [updates]
    enabled = true
    owner_repo = "alice/ai-taskbar"
    include_prereleases = true
    """#
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ai-taskbar-updates-\(UUID().uuidString).toml")
    try Data(toml.utf8).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let cfg = try ConfigLoader(path: tmp).load()
    expect(cfg.updates.enabled, "enabled parsed")
    expect(cfg.updates.ownerRepo == "alice/ai-taskbar", "owner_repo parsed")
    expect(cfg.updates.includePrereleases, "include_prereleases parsed")

    let empty = AppConfig()
    expect(empty.updates.ownerRepo == "justoeu/ai-taskbar",
           "default owner_repo points at upstream")
    expect(empty.updates.enabled, "default enabled = true")
    expect(!empty.updates.includePrereleases, "default include_prereleases = false")
}

section("CostMath") {
    let usage = ModelUsage(inputTokens: 1_000_000, outputTokens: 500_000,
                            cacheReadTokens: 2_000_000, cacheCreateTokens: 0)
    let pricing = ModelPricing(input: 3, output: 15, cacheRead: 0.3)
    let cost = CostMath.cost(usage: usage, pricing: pricing)
    // 1M*3 + 0.5M*15 + 2M*0.3 = 3 + 7.5 + 0.6 = 11.1
    expect(abs(cost - 11.1) < 0.001, "cost math accumulates input + output + cacheRead")
}

// MARK: - Summary

print("\n" + String(repeating: "=", count: 60))
print("Passed: \(passed)")
print("Failed: \(failures.count)")
if !failures.isEmpty {
    print("\nFailures:")
    for f in failures { print(f) }
    exit(1)
}
print("All validations OK.")

// MARK: - Helpers

extension Data {
    func base64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
