import Foundation

/// Which card a provider feeds. `VendorId` answers "which vendor" (name,
/// icon, pricing, status page); this answers "which instance of it", so two
/// Claude accounts can hold separate cache, history, pins and notifications.
///
/// `account == nil` is the single/legacy instance, whose `storageKey` is the
/// bare vendor raw value — exactly the key every persisted file and default
/// used before multi-account existed, so a one-account user migrates nothing.
public struct ProviderInstanceKey: Hashable, Codable, Sendable, Identifiable {
    public let vendor: VendorId
    public let account: String?

    public init(vendor: VendorId, account: String? = nil) {
        self.vendor = vendor
        self.account = account
    }

    /// File, directory and UserDefaults component: `anthropic` for the
    /// legacy instance, `anthropic.1a2b3c4d` for an extra account.
    public var storageKey: String {
        guard let account else { return vendor.rawValue }
        return "\(vendor.rawValue).\(account)"
    }

    public var id: String { storageKey }

    /// Inverse of `storageKey`; nil for a vendor that no longer exists.
    public init?(storageKey: String) {
        let parts = storageKey.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let vendor = VendorId(rawValue: first) else { return nil }
        let account = parts.count == 2 ? parts[1] : nil
        if let account, account.isEmpty { return nil }
        self.init(vendor: vendor, account: account)
    }
}
