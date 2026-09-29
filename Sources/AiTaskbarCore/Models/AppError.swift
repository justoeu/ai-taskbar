import Foundation

public enum AppError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case io(String)
    case credentials(String)
    case transport(String)
    case http(status: Int, body: String)
    case schema(String)
    case toml(String)
    case disabled(String)
    case other(String)
    /// A setup state the user resolves (install / sign in to a CLI). Carries
    /// structure so the App renders it in the user's language.
    case guidance(VendorGuidance)

    public var description: String {
        switch self {
        case .io(let m):              return "io: \(m)"
        case .credentials(let m):     return "credentials: \(m)"
        case .transport(let m):       return "transport: \(m)"
        case .http(let s, let b):     return "http \(s): \(b.prefix(200))"
        case .schema(let m):          return "schema mismatch: \(m)"
        case .toml(let m):            return "toml: \(m)"
        case .disabled(let m):        return "disabled: \(m)"
        case .other(let m):           return m
        case .guidance(let g):        return "guidance: \(g.diagnostic)"
        }
    }

    /// `LocalizedError` conformance — makes `error.localizedDescription` show
    /// our message instead of the generic "The operation couldn't be completed."
    public var errorDescription: String? { description }

    /// True for `disabled:` errors — used by the UI to render a friendly
    /// "no credentials" panel rather than a red error message. Decoupling
    /// from string-prefix matching makes the check refactor-proof.
    public var isDisabled: Bool {
        if case .disabled = self { return true }
        return false
    }

    /// True when retrying might help (network or server transient).
    public var isTransient: Bool {
        if case .transport = self { return true }
        guard let s = httpStatus else { return false }
        return s == 408 || s == 429 || (500...599).contains(s)
    }

    /// The HTTP status the error carries or is equivalent to: the real one
    /// for `.http`, `VendorGuidance.httpStatus` for `.guidance`, else nil.
    public var httpStatus: Int? {
        switch self {
        case .http(let s, _):   return s
        case .guidance(let g):  return g.httpStatus
        default:                return nil
        }
    }

    /// True only when the vendor responded with HTTP 429 (Too Many Requests).
    /// Scheduler uses this to extend the next sleep — see RefreshScheduler.
    public var isRateLimited: Bool {
        httpStatus == 429
    }

    /// True only when the vendor responded with HTTP 401 (Unauthorized). Used
    /// by the per-vendor UI to surface a "re-login" affordance instead of a
    /// generic red error — a 401 on an OAuth vendor (Codex/Claude) means the
    /// access token expired and a fresh login is the recovery, not a retry.
    public var isUnauthorized: Bool {
        httpStatus == 401
    }

    /// Wraps any error into an `AppError`, passing through if it's already one.
    /// Eliminates the `(error as? AppError) ?? AppError.other("\(error)")`
    /// boilerplate previously duplicated across all five providers.
    public static func wrapping(_ error: Error) -> AppError {
        (error as? AppError) ?? .other(String(describing: error))
    }
}
