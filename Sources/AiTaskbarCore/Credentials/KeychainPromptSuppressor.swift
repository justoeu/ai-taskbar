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
/// in the app — `KeychainAccessAuthorizer.authorize`'s exact-item read — deliberately
/// runs OUTSIDE this guard because its single password dialog is the
/// user-initiated point of the flow.
///
/// `SecKeychainSetUserInteractionAllowed` is deprecated alongside the rest of
/// the file-keychain API, but like the ACL surgery in
/// `KeychainAccessAuthorizer` it remains the only mechanism that governs
/// classic file-keychain prompts.
public enum KeychainPromptSuppressor {
    /// Serializes silent Keychain operations against the one user-initiated
    /// interactive read. Without this gate, a scheduled read could disable
    /// the process-global interaction flag while SecurityAgent is presenting
    /// the authorization dialog.
    // Recursive because the legacy explicit-read path performs a silent
    // account-metadata query inside its interactive operation on the same
    // thread. Other threads still wait until the interactive body finishes.
    private static let operationGate = NSRecursiveLock()

    private struct State {
        var depth: Int = 0
        /// User-initiated interactive window (Authorize). While true, `enter`
        /// must not force prompts off underneath the interactive body
        /// (RACE-HER-005).
        var interactiveHold: Bool = false
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Runs `body` with SecurityAgent keychain prompts disabled for this
    /// process, restoring interaction when the outermost suppressed section
    /// exits.
    public static func withPromptsSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        try withPromptsSuppressed(apply: setInteractionAllowed, body)
    }

    internal static func withPromptsSuppressed<T>(
        apply: @Sendable (Bool) -> Void,
        _ body: () throws -> T
    ) rethrows -> T {
        operationGate.lock()
        defer { operationGate.unlock() }
        enter(apply: apply)
        defer { exit(apply: apply) }
        return try body()
    }

    /// Runs `body` with SecurityAgent prompts explicitly ENABLED, then
    /// restores whatever state the current suppression depth implies.
    ///
    /// Never forces `allowed=true` while a suppressed section is nested
    /// (`depth > 0`). Sets `interactiveHold` so concurrent `enter()` cannot
    /// flip prompts off mid-Authorize (RACE-HER-005).
    public static func withPromptsAllowed<T>(_ body: () throws -> T) rethrows -> T {
        try withPromptsAllowed(apply: setInteractionAllowed, body)
    }

    internal static func withPromptsAllowed<T>(
        apply: @Sendable (Bool) -> Void,
        _ body: () throws -> T
    ) rethrows -> T {
        operationGate.lock()
        defer { operationGate.unlock() }
        state.withLock { s in
            s.interactiveHold = true
            if s.depth == 0 {
                apply(true)
            }
        }
        defer {
            state.withLock { s in
                s.interactiveHold = false
                apply(s.depth == 0)
            }
        }
        return try body()
    }

    internal static var testingInteractiveHold: Bool {
        state.withLock { $0.interactiveHold }
    }

    /// Internal-visibility seam so tests can drive the reference counting
    /// without touching the real (process-global) securityd flag.
    internal static func enter(apply: @Sendable (Bool) -> Void = Self.setInteractionAllowed) {
        state.withLock { s in
            if s.depth == 0 && !s.interactiveHold { apply(false) }
            s.depth += 1
        }
    }

    internal static func exit(apply: @Sendable (Bool) -> Void = Self.setInteractionAllowed) {
        state.withLock { s in
            s.depth -= 1
            if s.depth == 0 {
                // Depth 0 steady state is prompts allowed (interactiveHold
                // also wants true; suppressed sections always restore true
                // when the outermost exits).
                apply(true)
            }
        }
    }

    private static func setInteractionAllowed(_ allowed: Bool) {
        let status = SecKeychainSetUserInteractionAllowed(allowed)
        if status != errSecSuccess {
            AppLog.keychain.error("SecKeychainSetUserInteractionAllowed(\(allowed)) failed (OSStatus \(status)) — keychain prompts may appear")
        }
    }
}
