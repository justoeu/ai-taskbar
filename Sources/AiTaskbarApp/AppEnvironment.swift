import Foundation
import AiTaskbarCore
import AiTaskbarProviders

@MainActor
public final class AppEnvironment {
    public let http: HTTPClient
    public var configLoader: ConfigLoader
    public let config: AppConfig

    public init(http: HTTPClient, configLoader: ConfigLoader, config: AppConfig) {
        self.http = http
        self.configLoader = configLoader
        self.config = config
    }

    public static func live() -> AppEnvironment {
        do {
            let loader = try ConfigLoader()
            let cfg = try loader.load()
            // Top up the user's file with any sections we added since they
            // first ran the app (e.g. new vendors). Preserves their edits.
            if let appended = try? loader.ensureAllVendorSections(), !appended.isEmpty {
                AppLog.lifecycle.info("appended missing config sections: \(appended.joined(separator: ", "), privacy: .public)")
            }
            // Build HTTP client with TLS pinning if configured.
            let http: HTTPClient
            if !cfg.security.pinHosts.isEmpty {
                http = HTTPClient.pinned(pinnedHosts: cfg.security.pinHosts,
                                         auditOnly: cfg.security.pinAuditOnly)
                let suffix = cfg.security.pinAuditOnly ? " (audit only)" : ""
                AppLog.pinning.notice("TLS pinning active for \(cfg.security.pinHosts.count, privacy: .public) host(s)\(suffix, privacy: .public)")
            } else {
                http = HTTPClient()
            }
            return AppEnvironment(http: http, configLoader: loader, config: cfg)
        } catch {
            AppLog.lifecycle.error("config load failed (\(String(describing: error), privacy: .public)) — using defaults")
            // Fallback to a temp-path config so the app still launches.
            // Init(path:) is statically non-throwing — no force-unwrap needed.
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ai-taskbar-config.toml")
            let loader = ConfigLoader(path: tmp)
            return AppEnvironment(http: HTTPClient(),
                                  configLoader: loader,
                                  config: AppConfig())
        }
    }

    /// Build the set of providers indicated as enabled by the live config.
    /// Cache TTL is wired to `refresh_interval_seconds − 5 s` (floored at
    /// 15 s) so that:
    ///   1. Popover opens between scheduled refreshes still serve from
    ///      cache without a network round-trip.
    ///   2. The scheduled tick at T=interval ALWAYS finds an expired
    ///      cache (`age ≈ interval > ttl`), going straight to the network
    ///      without needing `forceRefresh: true`. The 5-second margin
    ///      absorbs Task.sleep jitter.
    public func makeProviders() -> [any UsageProvider] {
        let ttl = max(15, config.ui.refreshIntervalSeconds - 5)
        var out: [any UsageProvider] = []
        if config.anthropic.enabled {
            do {
                let p = try AnthropicProvider(
                    http: http,
                    keychainService: config.anthropic.keychainService ?? "Claude Code-credentials",
                    keychainAccount: config.anthropic.keychainAccount,
                    manageOAuthRefresh: config.anthropic.manageOAuthRefresh,
                    cacheTTL: ttl)
                out.append(p)
            } catch {
                AppLog.lifecycle.error("anthropic init failed: \(String(describing: error), privacy: .public)")
            }
        }
        if config.openai.enabled {
            do {
                let path = config.openai.codexAuthPath.map { URL(fileURLWithPath: $0) }
                let p = try OpenAIProvider(http: http, codexAuthPath: path,
                                           manageOAuthRefresh: config.openai.manageOAuthRefresh,
                                           cacheTTL: ttl)
                out.append(p)
            } catch {
                AppLog.lifecycle.error("openai init failed: \(String(describing: error), privacy: .public)")
            }
        }
        if config.openrouter.enabled {
            do {
                let p = try OpenRouterProvider(config: config.openrouter, http: http, cacheTTL: ttl)
                out.append(p)
            } catch {
                AppLog.lifecycle.error("openrouter init failed: \(String(describing: error), privacy: .public)")
            }
        }
        if config.zai.enabled {
            do {
                let p = try ZAIProvider(config: config.zai, http: http, cacheTTL: ttl)
                out.append(p)
            } catch {
                AppLog.lifecycle.error("zai init failed: \(String(describing: error), privacy: .public)")
            }
        }
        if config.kimi.enabled {
            do {
                let p = try KimiProvider(config: config.kimi, http: http, cacheTTL: ttl)
                out.append(p)
            } catch {
                AppLog.lifecycle.error("kimi init failed: \(String(describing: error), privacy: .public)")
            }
        }
        if config.gemini.enabled {
            do {
                let p = try GeminiProvider(config: config.gemini, http: http, cacheTTL: ttl)
                out.append(p)
            } catch {
                AppLog.lifecycle.error("gemini init failed: \(String(describing: error), privacy: .public)")
            }
        }
        if config.deepseek.enabled {
            do {
                let p = try DeepSeekProvider(config: config.deepseek, http: http, cacheTTL: ttl)
                out.append(p)
            } catch {
                AppLog.lifecycle.error("deepseek init failed: \(String(describing: error), privacy: .public)")
            }
        }
        if config.xai.enabled {
            do {
                let p = try XAIProvider(config: config.xai, http: http, cacheTTL: ttl)
                out.append(p)
            } catch {
                AppLog.lifecycle.error("xai init failed: \(String(describing: error), privacy: .public)")
            }
        }
        return out
    }
}
