import Testing
import Foundation
@testable import AiTaskbarCore
@testable import AiTaskbarProviders

/// ARCH-ATL-002: `UsageWindow.label` is the row identity (`ForEach(id: \.label)`)
/// and the notification-dedupe key, so a scoped "Opus" limit must not emit a
/// second "Opus (7d)" next to the flat `seven_day_opus` window.
@Suite("Anthropic scoped vs flat window dedupe")
struct AnthropicScopedDedupTests {
    private static let json = #"""
    {
      "five_hour": { "utilization": 10 },
      "seven_day": { "utilization": 20 },
      "seven_day_opus": { "utilization": 30 },
      "limits": [
        { "kind": "weekly_scoped", "percent": 40,
          "scope": { "model": { "display_name": "Opus" } } },
        { "kind": "weekly_scoped", "percent": 50,
          "scope": { "model": { "display_name": "Fable" } } }
      ]
    }
    """#

    private func snapshot() throws -> AnthropicSnapshot {
        let parsed = try JSONDecoder().decode(
            AnthropicUsageResponse.self, from: Data(Self.json.utf8))
        return parsed.toSnapshot(planLabel: nil)
    }

    @Test("window labels are unique when seven_day_opus and a scoped Opus coexist")
    func labelsUnique() throws {
        let labels = try VendorSnapshot.anthropic(snapshot()).windows.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    @Test("the flat seven_day_opus value wins over the scoped duplicate")
    func flatOpusWins() throws {
        let opus = try VendorSnapshot.anthropic(snapshot()).windows.filter { $0.label == "Opus (7d)" }
        #expect(opus.map(\.utilizationPercent) == [30])
    }

    @Test("an unrelated scoped model is still emitted")
    func otherScopedKept() throws {
        let labels = try snapshot().scoped.map(\.label)
        #expect(labels == ["Fable (7d)"])
    }

    @Test("a scoped Opus is kept when seven_day_opus is absent")
    func scopedOpusWithoutFlat() throws {
        let json = #"""
        { "limits": [ { "kind": "weekly_scoped", "percent": 40,
                        "scope": { "model": { "display_name": "Opus" } } } ] }
        """#
        let snap = try JSONDecoder().decode(
            AnthropicUsageResponse.self, from: Data(json.utf8)).toSnapshot(planLabel: nil)
        #expect(snap.scoped.map(\.label) == ["Opus (7d)"])
    }
}
