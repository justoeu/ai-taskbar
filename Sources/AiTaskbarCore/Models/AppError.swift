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
        switch self {
        case .transport:                  return true
        case .http(let s, _):             return s == 408 || s == 429 || (500...599).contains(s)
        default:                          return false
        }
    }

    /// Wraps any error into an `AppError`, passing through if it's already one.
    /// Eliminates the `(error as? AppError) ?? AppError.other("\(error)")`
    /// boilerplate previously duplicated across all five providers.
    public static func wrapping(_ error: Error) -> AppError {
        (error as? AppError) ?? .other(String(describing: error))
    }
}
