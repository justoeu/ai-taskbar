import Foundation
import Security
import CryptoKit

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
            NSLog("ai-taskbar: pinning — system trust eval failed for %@: %@",
                  host, String(describing: trustError))
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 2. Compute SPKI hash of the leaf certificate.
        guard let leafHash = Self.spkiHash(forLeafOf: serverTrust) else {
            NSLog("ai-taskbar: pinning — could not extract leaf SPKI for %@", host)
            if auditOnly {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        // 3. Compare against stored pin or seed it (TOFU).
        if let stored = store.get(host: host) {
            if stored == leafHash {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                NSLog("ai-taskbar: TLS pin mismatch for %@ (stored=%@, presented=%@)%@",
                      host, stored, leafHash,
                      auditOnly ? " — audit only, proceeding" : "")
                if auditOnly {
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
        } else {
            store.set(host: host, hash: leafHash)
            NSLog("ai-taskbar: TLS pin SEEDED for %@ → %@", host, leafHash)
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        }
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
