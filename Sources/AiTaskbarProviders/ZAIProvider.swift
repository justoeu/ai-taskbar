import Foundation
import os
import AiTaskbarCore

public final class ZAIProvider: UsageProvider {
    public let vendorId: VendorId = .zai
    private let credentials: EnvOrConfigCredentialReader
    private let fetcher: CachedFetch
    private let http: HTTPClient
    private let configTier: String?
    private let now: @Sendable () -> Date
    /// A failed list read pauses list reads for an hour, so a server that
    /// refuses it neither fails the card nor doubles every call.
    private let resetListPausedUntil = OSAllocatedUnfairLock<Date?>(initialState: nil)
    static let resetListPause: TimeInterval = 3600
    /// User-clicked quota resets (`docs/SDD-zai-quota-reset.md`).
    public let limitResets: ZAILimitResetService

    public init(credentials: EnvOrConfigCredentialReader,
                cache: DiskCache,
                http: HTTPClient,
                configTier: String? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.fetcher = CachedFetch(cache: cache)
        self.http = http
        self.configTier = configTier
        self.now = now
        self.limitResets = ZAILimitResetService(credentials: credentials, http: http, now: now)
    }

    public convenience init(config: ZAIConfig,
                            http: HTTPClient = .init(),
                            cacheTTL: TimeInterval = 300) throws {
        let cache = try DiskCache.defaultFor(.zai, ttl: cacheTTL)
        self.init(
            credentials: EnvOrConfigCredentialReader(
                envVarName: config.apiKeyEnv,
                inlineKey: config.apiKey,
                vendorName: "Z.AI"
            ),
            cache: cache,
            http: http,
            configTier: config.planTier
        )
    }

    public func fetchUsage(forceRefresh: Bool) async throws -> FetchOutcome {
        try await fetcher.run(
            forceRefresh: forceRefresh,
            decode: decodeSnapshot,
            fetch: { [self] in
                let apiKey = try credentials.read()
                // Same-origin redirects only: the raw key rides in the header.
                let (usage, response) = try await http.sendBounded(
                    ZAIRequests.request(ZAIRequests.usageURL, apiKey: apiKey),
                    maximumResponseBytes: HTTPClient.defaultMaximumResponseBytes)
                guard (200..<300).contains(response.statusCode) else {
                    throw AppError.http(status: response.statusCode,
                                        body: String(decoding: usage.prefix(1024), as: UTF8.self))
                }
                try Task.checkCancellation()
                return try await withResetList(usage, apiKey: apiKey)
            }
        )
    }

    /// The reset list is read only while the 5-hour or weekly window is
    /// above 90% — the only time a reset can be offered. Its failure costs
    /// the reset button, never the usage numbers.
    private func withResetList(_ usage: Data, apiKey: String) async throws -> Data {
        let now = self.now()
        let paused = resetListPausedUntil.withLock { $0.map { $0 > now } ?? false }
        guard !paused, Self.isNearLimit(usage) else { return usage }
        do {
            let (data, response) = try await http.sendBounded(
                ZAIRequests.request(ZAIRequests.resetListURL, apiKey: apiKey),
                maximumResponseBytes: ZAIRequests.resetResponseLimit)
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode) else {
                throw AppError.http(status: response.statusCode, body: "")
            }
            guard let list = try ZAIResetList.decodeResponse(data) else {
                throw AppError.schema("zai reset list reported failure")
            }
            return try list.merging(into: usage)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLog.network.error(
                "zai reset list failed, paused for 1 h: \(String(describing: error), privacy: .public)")
            let until = self.now().addingTimeInterval(Self.resetListPause)
            resetListPausedUntil.withLock { $0 = until }
            return usage
        }
    }

    static func isNearLimit(_ payload: Data) -> Bool {
        guard let parsed = try? SharedCoders.decoder.decode(ZAIEnvelope.self, from: payload),
              parsed.data != nil else {
            return false // the decode path reports schema drift itself
        }
        return parsed.toSnapshot(configTier: nil).hasWindowAboveResetThreshold
    }

    private func decodeSnapshot(_ data: Data) throws -> VendorSnapshot {
        let parsed: ZAIEnvelope
        do {
            parsed = try SharedCoders.decoder.decode(ZAIEnvelope.self, from: data)
        } catch {
            throw AppError.schema("zai usage decode: \(error)")
        }

        if let code = parsed.code, code != 200 {
            let rawMsg = parsed.msg ?? "Z.AI error (\(code))"
            let msg = rawMsg.contains("不存在coding plan")
                ? "\(rawMsg) (Conta Z.AI sem plano de coding ativo)"
                : rawMsg
            throw AppError.http(status: code, body: msg)
        }
        if let success = parsed.success, !success {
            let rawMsg = parsed.msg ?? "Z.AI request unsuccessful"
            let msg = rawMsg.contains("不存在coding plan")
                ? "\(rawMsg) (Conta Z.AI sem plano de coding ativo)"
                : rawMsg
            throw AppError.http(status: parsed.code ?? 500, body: msg)
        }
        guard parsed.data != nil else {
            let detail = parsed.msg.map { ": \($0)" } ?? ""
            throw AppError.schema("Resposta da Z.AI sem dados de quota\(detail)")
        }
        return .zai(parsed.toSnapshot(configTier: configTier))
    }
}
