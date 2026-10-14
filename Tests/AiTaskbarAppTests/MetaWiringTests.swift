import Testing
import Foundation
import os
@testable import AiTaskbarApp
import AiTaskbarCore

@Suite("Meta app wiring (SDD-meta-muse §11)")
struct MetaWiringTests {
    @MainActor private func env(metaEnabled: Bool) -> AppEnvironment {
        var config = AppConfig()
        config.meta.enabled = metaEnabled
        return AppEnvironment(http: HTTPClient(),
                              configLoader: ConfigLoader(path: URL(fileURLWithPath: "/tmp/unused-\(UUID().uuidString).toml")),
                              config: config)
    }

    @Test("enabled meta appears in vendor ids; disabled does not")
    @MainActor func enabled_vendor_ids() {
        expectTrue(env(metaEnabled: true).enabledVendorIds().contains(.meta))
        expectFalse(env(metaEnabled: false).enabledVendorIds().contains(.meta))
    }

    @Test("disabled Meta never invokes the scanner seam (SDD §4.3)")
    @MainActor func disabled_never_scans() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let e = CostEstimator(
            claudeEstimate: { CostEstimate(usdToday: 0, usdLast7Days: 0) },
            codexEstimate: { CostEstimate(usdToday: 0, usdLast7Days: 0) },
            opencodeScan: { _ in [:] },
            museEstimate: { calls.withLock { $0 += 1 }; return CostEstimate(usdToday: 0, usdLast7Days: 0) },
            museEnabled: false)
        e.refresh(force: true)
        let deadline = Date().addingTimeInterval(5)
        while e.isLoading, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(e.byVendor[.meta] == nil)
    }

    @Test("sessions dir override expands tilde; empty means default")
    func sessions_dir_override() {
        var cfg = MetaConfig()
        #expect(AppEnvironment.museSessionsDir(for: cfg) == nil)
        cfg.sessionsDir = "  "
        #expect(AppEnvironment.museSessionsDir(for: cfg) == nil)
        cfg.sessionsDir = "/tmp/muse-sessions"
        #expect(AppEnvironment.museSessionsDir(for: cfg)?.path == "/tmp/muse-sessions")
        cfg.sessionsDir = "~/muse-sessions"
        let expanded = AppEnvironment.museSessionsDir(for: cfg)?.path ?? ""
        expectTrue(expanded.hasSuffix("/muse-sessions"))
        expectFalse(expanded.hasPrefix("~"))
    }
}
