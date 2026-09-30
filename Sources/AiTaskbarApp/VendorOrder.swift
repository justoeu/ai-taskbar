import Foundation
import AiTaskbarCore

/// User-controlled display order for vendor cards in the popover.
///
/// Persisted in `UserDefaults` under `vendor_order` (array of `VendorId.rawValue`),
/// same pattern as per-card expand state (`expanded_<vendor>`). Instant, no relaunch.
///
/// Sort rules:
/// - **No saved order** → configured vendors first, then unconfigured; alpha within bucket.
/// - **Saved order** → follow it for known IDs; any new/enabled vendor not in the list
///   is appended (configured first, then alpha).
public enum VendorOrder {
    public static let defaultsKey = "vendor_order"

    public static func load(from defaults: UserDefaults = .standard) -> [VendorId] {
        (defaults.stringArray(forKey: defaultsKey) ?? []).compactMap(VendorId.init(rawValue:))
    }

    public static func save(_ order: [VendorId], to defaults: UserDefaults = .standard) {
        defaults.set(order.map(\.rawValue), forKey: defaultsKey)
    }

    public static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// One ↑/↓ step within an independent ordering (Analytics, Status).
    /// `order` is the persisted list, `visible` the vendors currently shown in
    /// display order; visible vendors missing from `order` are appended in
    /// their visible order first. No-op at either end.
    public static func moved(_ id: VendorId, up: Bool, order: [VendorId], visible: [VendorId]) -> [VendorId] {
        var current = order.filter { visible.contains($0) }
        for v in visible where !current.contains(v) { current.append(v) }
        guard let idx = current.firstIndex(of: id) else { return current }
        let target = up ? idx - 1 : idx + 1
        guard current.indices.contains(target) else { return current }
        current.swapAt(idx, target)
        return current
    }

    /// Pure ordering of currently available vendor IDs.
    public static func ordered(
        entries: [(id: VendorId, unconfigured: Bool)],
        preferred: [VendorId]
    ) -> [VendorId] {
        guard !entries.isEmpty else { return [] }
        let available = Set(entries.map(\.id))

        if preferred.isEmpty {
            return defaultSorted(entries)
        }

        var seen = Set<VendorId>()
        var result: [VendorId] = []
        for id in preferred where available.contains(id) {
            if seen.insert(id).inserted {
                result.append(id)
            }
        }
        let missing = entries.filter { !seen.contains($0.id) }
        result.append(contentsOf: defaultSorted(missing))
        return result
    }

    private static func defaultSorted(_ entries: [(id: VendorId, unconfigured: Bool)]) -> [VendorId] {
        entries.sorted { a, b in
            if a.unconfigured != b.unconfigured {
                return !a.unconfigured && b.unconfigured
            }
            return a.id.rawValue < b.id.rawValue
        }.map(\.id)
    }
}
