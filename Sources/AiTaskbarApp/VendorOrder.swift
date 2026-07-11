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

    public static func moving(_ order: [VendorId],
                              fromOffsets: IndexSet,
                              toOffset: Int) -> [VendorId] {
        var copy = order
        copy.move(fromOffsets: fromOffsets, toOffset: toOffset)
        return copy
    }

    /// Move `id` so it sits immediately before `target`. If `target` is nil
    /// or not in the list, append. No-op when `id == target` or `id` missing.
    public static func moving(_ order: [VendorId],
                              id: VendorId,
                              before target: VendorId?) -> [VendorId] {
        guard id != target, let from = order.firstIndex(of: id) else { return order }
        var copy = order
        copy.remove(at: from)
        if let target, let to = copy.firstIndex(of: target) {
            copy.insert(id, at: to)
        } else {
            copy.append(id)
        }
        return copy
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
