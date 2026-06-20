import Foundation
import AiTaskbarCore

/// `GET <baseURL>/user/balance`. DeepSeek's only account-level endpoint —
/// it does NOT expose token usage, quota windows, or cost history. The
/// response is the current prepaid balance, possibly in two currencies:
///
/// {
///   "is_available": true,
///   "balance_infos": [
///     { "currency": "CNY", "total_balance": "110.00",
///       "granted_balance": "10.00", "topped_up_balance": "100.00" }
///   ]
/// }
///
/// All balance fields arrive as JSON **strings** (e.g. `"110.00"`), so the
/// decoder falls back to string→Double on top of the standard
/// `flexibleDouble` int/float tolerance.
public struct DeepSeekBalanceResponse: Decodable {
    public let isAvailable: Bool?
    public let balanceInfos: [DeepSeekBalanceInfo]?

    enum CodingKeys: String, CodingKey {
        case isAvailable   = "is_available"
        case balanceInfos  = "balance_infos"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isAvailable  = try c.decodeIfPresent(Bool.self, forKey: .isAvailable)
        balanceInfos = try c.decodeIfPresent([DeepSeekBalanceInfo].self, forKey: .balanceInfos)
    }
}

public struct DeepSeekBalanceInfo: Decodable {
    public let currency: String?
    public let totalBalance: Double?
    public let grantedBalance: Double?
    public let toppedUpBalance: Double?

    enum CodingKeys: String, CodingKey {
        case totalBalance    = "total_balance"
        case grantedBalance  = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
        case currency
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currency        = try c.decodeIfPresent(String.self, forKey: .currency)
        totalBalance    = Self.numeric(c, .totalBalance)
        grantedBalance  = Self.numeric(c, .grantedBalance)
        toppedUpBalance = Self.numeric(c, .toppedUpBalance)
    }

    /// Like `flexibleDoubleIfPresent` but also tolerates string-encoded
    /// numbers (`"110.00"`), which DeepSeek sends for every balance field.
    private static func numeric(_ c: KeyedDecodingContainer<CodingKeys>,
                                _ key: CodingKeys) -> Double? {
        if let d = c.flexibleDoubleIfPresent(forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key), let d = Double(s) { return d }
        return nil
    }
}

extension DeepSeekBalanceResponse {
    public func toSnapshot() -> DeepSeekSnapshot {
        // Prefer a USD entry; fall back to CNY; fall back to the first entry.
        let infos = balanceInfos ?? []
        let picked = infos.first { ($0.currency ?? "").uppercased() == "USD" }
            ?? infos.first { ($0.currency ?? "").uppercased() == "CNY" }
            ?? infos.first

        let currency = picked?.currency?.uppercased()
        let total = picked?.totalBalance ?? 0
        let granted = picked?.grantedBalance
        let toppedUp = picked?.toppedUpBalance
        let available = total

        // DeepSeek doesn't expose a quota window, so we display this as a
        // flat "balance" row with 0% utilization — the progress bar is a
        // visual anchor; the detail string carries the actual amount.
        let symbol = (currency == "CNY") ? "¥" : "$"
        let balanceWindow = UsageWindow(
            label: "Balance",
            utilizationPercent: 0,
            resetsAt: nil,
            detail: String(format: "%@%.2f available", symbol, available)
        )
        return DeepSeekSnapshot(
            planLabel: "DeepSeek",
            balance: balanceWindow,
            totalBalance: total,
            grantedBalance: granted,
            toppedUpBalance: toppedUp,
            currency: currency,
            isAvailable: isAvailable
        )
    }
}
