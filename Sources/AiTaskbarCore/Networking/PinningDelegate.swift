import Foundation
import Security
import CryptoKit
import os

/// `URLSessionDelegate` that enforces TLS pinning on a configured set of
/// hosts using SHA256 over the leaf certificate's Subject Public Key Info.
///
/// Trust-On-First-Use: when the host is pinned but no stored hash exists,
/// the first successful connection seeds the pin. Subsequent connections
/// reject any cert whose SPKI hash differs.
///
/// Non-pinned hosts fall through to default system trust evaluation.
public final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    public let pinnedHosts: Set<String>
    public let store: PinStore
    public let auditOnly: Bool

    public init(pinnedHosts: [String], store: PinStore, auditOnly: Bool = false) {
        self.pinnedHosts = Set(pinnedHosts.map { $0.lowercased() })
        self.store = store
        self.auditOnly = auditOnly
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod
              == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host.lowercased()
        guard pinnedHosts.contains(host),
              let serverTrust = challenge.protectionSpace.serverTrust else {
            // Non-pinned host → fall through to system trust store. Cancel
            // if pinned host has no serverTrust (defensive — shouldn't happen).
            if pinnedHosts.contains(host) {
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        // 1. Standard system trust evaluation. We never accept a cert that
        // the system would reject — pinning is a *narrowing* of system trust,
        // not a replacement.
        var trustError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &trustError) else {
            AppLog.pinning.error("system trust eval failed for \(host, privacy: .public): \(String(describing: trustError), privacy: .public)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 2. Compute SPKI hash of the leaf certificate.
        let leafHash = Self.spkiHash(forLeafOf: serverTrust)
        // Resolve the effective stored hash: TOFU'd file pin first, then the
        // baked-in `PinBaseline` (which prevents first-connection MitM by
        // shipping pin values in-binary for known vendor hosts). When neither
        // has a value for `host`, TOFU seeding applies.
        let stored = store.get(host: host) ?? PinBaseline.pin(for: host)

        // 3. Pure decision over (leafHash, stored, auditOnly). Centralized so
        // the TOFU + mismatch + audit-only logic is unit-testable without a
        // live SecTrust.
        switch Self.evaluate(leafHash: leafHash, storedHash: stored, auditOnly: auditOnly) {
        case .accept:
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case .reject(let reason):
            AppLog.pinning.error("\(reason.message(host: host, leafHash: leafHash, storedHash: stored), privacy: .public)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .acceptWithWarning(let reason):
            AppLog.pinning.warning("\(reason.message(host: host, leafHash: leafHash, storedHash: stored), privacy: .public)")
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case .seed(let hash):
            // Only TOFU-able when no baseline pin exists for this host —
            // otherwise seeding would let an attacker overwrite the shipped
            // baseline. Skip the write but still accept (the baseline already
            // matches the presented hash, since evaluate() returned .seed
            // only when `storedHash == nil`).
            if PinBaseline.pin(for: host) == nil {
                store.set(host: host, hash: hash)
                AppLog.pinning.info("TLS pin SEEDED for \(host, privacy: .public) → \(hash, privacy: .private)")
            }
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        }
    }

    /// Pure decision function extracted from `urlSession(_:didReceive:)`. Takes
    /// the computed leaf SPKI hash, the currently-stored pin (if any), and the
    /// audit-only flag, and returns the verdict. The delegate method then
    /// translates to URLSession disposition + side effects (seed write, log).
    ///
    /// Exposed publicly so the security-critical TOFU + mismatch + audit-only
    /// branches can be unit-tested without standing up a real `SecTrust`.
    public enum Decision: Equatable {
        /// Pin matched, or leaf hash extracted and matches stored.
        case accept
        /// Pin mismatch, enforcement on.
        case reject(Reason)
        /// Pin mismatch, audit-only — log but proceed.
        case acceptWithWarning(Reason)
        /// No stored pin yet — caller should seed `hash` and accept.
        case seed(hash: String)

        public enum Reason: Equatable, Sendable {
            case spkiExtractionFailed
            case mismatch

            func message(host: String, leafHash: String?, storedHash: String?) -> String {
                switch self {
                case .spkiExtractionFailed:
                    return "could not extract leaf SPKI for \(host)"
                case .mismatch:
                    let leaf = leafHash ?? "<nil>"
                    let stored = storedHash ?? "<nil>"
                    return "TLS pin mismatch for \(host) (stored=\(stored), presented=\(leaf))"
                }
            }
        }
    }

    @inline(__always)
    public static func evaluate(leafHash: String?,
                                storedHash: String?,
                                auditOnly: Bool) -> Decision {
        // Could not extract SPKI from leaf cert. Audit-only lets us proceed
        // (the system trust check already passed in step 1); otherwise reject.
        guard let leafHash else {
            return auditOnly ? .acceptWithWarning(.spkiExtractionFailed) : .reject(.spkiExtractionFailed)
        }
        // No stored pin → TOFU: seed it.
        guard let storedHash else {
            return .seed(hash: leafHash)
        }
        // Mismatch — audit-only proceeds, otherwise cancel.
        if storedHash == leafHash {
            return .accept
        }
        return auditOnly ? .acceptWithWarning(.mismatch) : .reject(.mismatch)
    }

    /// Extracts the leaf certificate from a SecTrust, copies its public key,
    /// and SHA256s the DER-encoded SPKI. Base64-encoded result is comparable
    /// across runs.
    public static func spkiHash(forLeafOf trust: SecTrust) -> String? {
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
        guard let leaf = chain?.first else { return nil }
        return spkiHash(of: leaf)
    }

    public static func spkiHash(of cert: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(cert),
              let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { return nil }
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
    }
}
