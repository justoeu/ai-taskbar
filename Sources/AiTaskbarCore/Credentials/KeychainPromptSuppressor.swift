import Foundation
import Security
import os

/// Process-wide SecurityAgent prompt suppression for Keychain operations.
///
/// `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` only suppresses the
/// trusted-application Allow/Deny confirmation. It does NOT suppress the
/// partition-list password dialog (`KeychainPromptAclSubject`): when the
/// item's trusted-app list matches nothing (or the partition list lacks this
/// binary's `teamid:`), securityd falls through to "ask for the login
/// keychain password" and displays it regardless of the UIFail hint —
/// verified in the field on macOS 26 (`securityd kcacl: displaying keychain
/// prompt for …`), and reproducible with a two-binary probe: UIFail alone
/// blocks on the dialog; with `SecKeychainSetUserInteractionAllowed(false)`
/// the same read fast-fails `errSecAuthFailed` in <10 ms with no UI.
///
/// So every Keychain call that must never pop UI (all scheduled reads and
/// write-backs) runs inside `withPromptsSuppressed`. The flag is per-process
/// global, hence the reference count: overlapping suppressed sections keep
/// it off until the outermost one exits. The only interactive Keychain call
/// in the app — `KeychainAccessAuthorizer.authorize`'s commit — deliberately
/// runs OUTSIDE this guard because its single password dialog is the
/// user-initiated point of the flow.
///
/// `SecKeychainSetUserInteractionAllowed` is deprecated alongside the rest of
/// the file-keychain API, but like the ACL surgery in
/// `KeychainAccessAuthorizer` it remains the only mechanism that governs
/// classic file-keychain prompts.
public enum KeychainPromptSuppressor {
    private static let depth = OSAllocatedUnfairLock(initialState: 0)

    /// Runs `body` with SecurityAgent keychain prompts disabled for this
    /// process, restoring interaction when the outermost suppressed section
    /// exits.
    public static func withPromptsSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        enter()
        defer { exit() }
        return try body()
    }

    /// Internal-visibility seam so tests can drive the reference counting
    /// without touching the real (process-global) securityd flag.
    internal static func enter(apply: @Sendable (Bool) -> Void = Self.setInteractionAllowed) {
        depth.withLock { d in
            if d == 0 { apply(false) }
            d += 1
        }
    }

    internal static func exit(apply: @Sendable (Bool) -> Void = Self.setInteractionAllowed) {
        depth.withLock { d in
            d -= 1
            if d == 0 { apply(true) }
        }
    }

    private static func setInteractionAllowed(_ allowed: Bool) {
        let status = SecKeychainSetUserInteractionAllowed(allowed)
        if status != errSecSuccess {
            AppLog.keychain.error("SecKeychainSetUserInteractionAllowed(\(allowed)) failed (OSStatus \(status)) — keychain prompts may appear")
        }
    }
}
