import Foundation
import AiTaskbarCore

/// `GET <baseURL>/users/me/balance`. The Moonshot API has shipped at least
/// two response shapes in the wild — newer responses split balance into
/// available/voucher/cash, older just expose `balance`. Both are tolerated.
public struct KimiBalanceResponse: Decodable {
    public let code: Int?
    public let status: Bool?
    public let scode: String?
    public let data: KimiBalanceData?
}

public struct KimiBalanceData: Decodable {
    public let availableBalance: Double?
    public let voucherBalance: Double?
    public let cashBalance: Double?
    /// Older field used when the response doesn't break out available/voucher/cash.
    public let balance: Double?

    enum CodingKeys: String, CodingKey {
        case availableBalance = "available_balance"
        case voucherBalance   = "voucher_balance"
        case cashBalance      = "cash_balance"
        case balance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Kimi's balance fields can also arrive as strings ("87.65"), so use
        // a Kimi-specific decoder that adds the string fallback on top of
        // the standard flexibleDouble.
        availableBalance = Self.numeric(c, .availableBalance)
        voucherBalance   = Self.numeric(c, .voucherBalance)
        cashBalance      = Self.numeric(c, .cashBalance)
        balance          = Self.numeric(c, .balance)
    }

    /// Like `flexibleDoubleIfPresent` but also tolerates string-encoded
    /// numbers (`"87.65"`), which Moonshot has been observed to send for
    /// balance fields.
    private static func numeric(_ c: KeyedDecodingContainer<CodingKeys>,
                                _ key: CodingKeys) -> Double? {
        if let d = c.flexibleDoubleIfPresent(forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key), let d = Double(s) { return d }
        return nil
    }
}

extension KimiBalanceResponse {
    public func toSnapshot() -> KimiSnapshot {
        let available = data?.availableBalance ?? data?.balance ?? 0
        let voucher   = data?.voucherBalance
        let cash      = data?.cashBalance

        // Moonshot doesn't expose a top-up cap, so we display this as a flat
        // "balance" row with 0% utilization — the progress bar serves as a
        // visual anchor; the detail string carries the actual dollar amount.
        let balanceWindow = UsageWindow(
            label: "Balance",
            utilizationPercent: 0,
            resetsAt: nil,
            detail: String(format: "$%.2f available", available)
        )
        return KimiSnapshot(
            planLabel: "Moonshot · Kimi",
            balance: balanceWindow,
            availableUSD: available,
            voucherUSD: voucher,
            cashUSD: cash
        )
    }
}
