import Foundation
import ServiceManagement
import AiTaskbarCore

/// Thin wrapper around `SMAppService.mainApp`. Note that this only works when
/// the app is launched from an installed location (e.g. /Applications) — when
/// running directly out of the build directory, register() returns an error
/// the caller should surface to the user.
@MainActor
public final class LoginItemService: ObservableObject {
    @Published public private(set) var isRegistered: Bool

    public init() {
        self.isRegistered = Self.currentStatus() == .enabled
    }

    public static func currentStatus() -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    public var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:        return "Enabled"
        case .requiresApproval: return "Requires approval in System Settings"
        case .notFound:       return "Not registered"
        case .notRegistered:  return "Not registered"
        @unknown default:     return "Unknown"
        }
    }

    public func toggle() {
        if isRegistered {
            unregister()
        } else {
            register()
        }
    }

    public func register() {
        do {
            try SMAppService.mainApp.register()
            refresh()
        } catch {
            AppLog.lifecycle.error("SMAppService.register failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            refresh()
        } catch {
            AppLog.lifecycle.error("SMAppService.unregister failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func refresh() {
        isRegistered = SMAppService.mainApp.status == .enabled
    }
}
